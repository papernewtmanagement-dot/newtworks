-- =====================================================================
-- Company holidays, per the handbook page "Hours & Time Off" > Office Hours.
--
-- The handbook names two distinct kinds of day and they behave differently:
--
--   CLOSED (6): New Year's Day, Memorial Day, Independence Day, Labor Day,
--     Thanksgiving, Christmas Day. "the agency is closed in observance of
--     national holidays" when they land on a weekday. Nobody is expected to
--     work, so nothing is expected of anybody.
--
--   NON-STANDARD BUSINESS DAY (2): the day after Thanksgiving, and Christmas
--     Eve. "While the office is open those days, it is not required to have
--     any team members physically in office." A teammate who wants the day
--     off "must schedule it as a normal day" — which creates its own
--     time_off_requests row. So these days are still expected work days and
--     must NOT be auto-excluded from anything.
--
-- Also from the same page, and the reason nothing here touches targets:
--   "WIN THE WEEK still applies every week, regardless of holidays and
--    non-standard business days."
-- Quote minimums and Sales Points targets are deliberately untouched.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.company_holidays (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id      uuid NOT NULL,
  holiday_date   date NOT NULL,
  holiday_name   text NOT NULL,
  -- 'closed'       = agency closed, nobody expected to work
  -- 'non_standard' = office open, no in-office requirement, still a work day
  observance     text NOT NULL DEFAULT 'closed',
  -- stable key for the eight handbook holidays, so re-seeding a year is
  -- idempotent. NULL means a one-off holiday somebody added by hand; the
  -- seeder never touches or deletes those.
  rule_key       text,
  is_active      boolean NOT NULL DEFAULT true,
  notes          text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT company_holidays_observance_check
    CHECK (observance IN ('closed', 'non_standard'))
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_company_holidays_rule_year
  ON public.company_holidays (agency_id, rule_key, (EXTRACT(year FROM holiday_date)))
  WHERE rule_key IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ux_company_holidays_date_name
  ON public.company_holidays (agency_id, holiday_date, holiday_name);

CREATE INDEX IF NOT EXISTS idx_company_holidays_lookup
  ON public.company_holidays (agency_id, holiday_date)
  WHERE is_active AND observance = 'closed';

ALTER TABLE public.company_holidays ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='company_holidays'
      AND policyname='company_holidays_authenticated_read'
  ) THEN
    CREATE POLICY company_holidays_authenticated_read
      ON public.company_holidays FOR SELECT TO authenticated USING (true);
  END IF;
END $$;

REVOKE ALL ON public.company_holidays FROM anon, PUBLIC;
GRANT SELECT ON public.company_holidays TO authenticated;

COMMENT ON TABLE public.company_holidays IS
  'Agency holidays per handbook "Hours & Time Off" > Office Hours. observance=closed means the agency is shut and nothing is expected of anyone; observance=non_standard means the office is open with no in-office requirement and it is still a normal expected work day. Seeded by seed_company_holidays().';


-- ---------------------------------------------------------------------
-- Date math helper. Keeps the weekday arithmetic in exactly one place so
-- the seeder stays readable.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.nth_weekday_of_month(
  p_year int, p_month int, p_isodow int, p_nth int
) RETURNS date
LANGUAGE sql IMMUTABLE AS $function$
  -- p_isodow: Monday=1 .. Sunday=7. p_nth: 1-based, or -1 for the last one.
  SELECT CASE
    WHEN p_nth > 0 THEN
      make_date(p_year, p_month, 1)
        + ((p_isodow - EXTRACT(isodow FROM make_date(p_year, p_month, 1))::int + 7) % 7)
        + (7 * (p_nth - 1))
    ELSE
      (make_date(p_year, p_month, 1) + INTERVAL '1 month - 1 day')::date
        - ((EXTRACT(isodow FROM (make_date(p_year, p_month, 1) + INTERVAL '1 month - 1 day')::date)::int
            - p_isodow + 7) % 7)
  END;
$function$;


-- ---------------------------------------------------------------------
-- Seed one calendar year of handbook holidays. Idempotent: re-running
-- corrects dates and names in place and never duplicates.
--
-- Rows are written for the true calendar date even when it falls on a
-- weekend. The handbook grants closure only "when they land on a weekday"
-- and names no shifted observance day, so no Friday/Monday substitution is
-- invented here — a weekend row simply never affects a weekday calculation.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.seed_company_holidays(
  p_agency_id uuid, p_year int
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_thanksgiving date;
  v_inserted int := 0;
  v_updated  int := 0;
  v_rec      record;
BEGIN
  v_thanksgiving := public.nth_weekday_of_month(p_year, 11, 4, 4);  -- 4th Thursday in November

  FOR v_rec IN
    SELECT * FROM (VALUES
      ('new_years_day',          make_date(p_year, 1, 1),                                    'New Year''s Day',            'closed'),
      ('memorial_day',           public.nth_weekday_of_month(p_year, 5, 1, -1),              'Memorial Day',               'closed'),
      ('independence_day',       make_date(p_year, 7, 4),                                    'Independence Day',           'closed'),
      ('labor_day',              public.nth_weekday_of_month(p_year, 9, 1, 1),               'Labor Day',                  'closed'),
      ('thanksgiving',           v_thanksgiving,                                             'Thanksgiving',               'closed'),
      ('day_after_thanksgiving', v_thanksgiving + 1,                                         'Day After Thanksgiving',     'non_standard'),
      ('christmas_eve',          make_date(p_year, 12, 24),                                  'Christmas Eve',              'non_standard'),
      ('christmas_day',          make_date(p_year, 12, 25),                                  'Christmas Day',              'closed')
    ) AS t(rule_key, holiday_date, holiday_name, observance)
  LOOP
    UPDATE public.company_holidays h
       SET holiday_date = v_rec.holiday_date,
           holiday_name = v_rec.holiday_name,
           observance   = v_rec.observance,
           updated_at   = now()
     WHERE h.agency_id = p_agency_id
       AND h.rule_key  = v_rec.rule_key
       AND EXTRACT(year FROM h.holiday_date) = p_year;

    IF FOUND THEN
      v_updated := v_updated + 1;
    ELSE
      INSERT INTO public.company_holidays
        (agency_id, holiday_date, holiday_name, observance, rule_key, notes)
      VALUES
        (p_agency_id, v_rec.holiday_date, v_rec.holiday_name, v_rec.observance, v_rec.rule_key,
         'Seeded from handbook "Hours & Time Off" > Office Hours.');
      v_inserted := v_inserted + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('year', p_year, 'inserted', v_inserted, 'updated', v_updated);
END $function$;


-- ---------------------------------------------------------------------
-- Automation handler. run_internal_recipe() calls any public function
-- taking (agency_id, recipe_id) and returning jsonb, so no edge function
-- change is needed to register this.
--
-- Seeds the current year AND the next one, so the table is always at least
-- twelve months ahead no matter when it last ran. Safe to run as often as
-- you like — the seeder is idempotent.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.seed_company_holidays_runner(
  p_agency_id uuid, p_recipe_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_year int := EXTRACT(year FROM (now() AT TIME ZONE 'America/Chicago'))::int;
  v_this jsonb;
  v_next jsonb;
  v_total int;
BEGIN
  v_this := public.seed_company_holidays(p_agency_id, v_year);
  v_next := public.seed_company_holidays(p_agency_id, v_year + 1);

  v_total := (v_this->>'inserted')::int + (v_this->>'updated')::int
           + (v_next->>'inserted')::int + (v_next->>'updated')::int;

  RETURN jsonb_build_object(
    'records_processed', v_total,
    'output_summary', format(
      'Holidays seeded for %s (%s new, %s refreshed) and %s (%s new, %s refreshed).',
      v_year, v_this->>'inserted', v_this->>'updated',
      v_year + 1, v_next->>'inserted', v_next->>'updated'),
    'this_year', v_this,
    'next_year', v_next
  );
END $function$;

GRANT EXECUTE ON FUNCTION public.seed_company_holidays(uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.seed_company_holidays_runner(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.nth_weekday_of_month(int, int, int, int) TO authenticated, anon;
