-- Handbook "Hours & Time Off" > Office Hours:
--   "Any full time ACCOUNT ASSOCIATES employed during these days will receive the
--    day off if it falls on a normal working day. This time off will be in addition
--    to their normal accrued PTO."
--
-- Account Managers are salaried and already get a four-day week through Win the
-- Week, so the handbook grants this specifically to Account Associates, who are
-- hourly — the point is the day is PAID and does not consume accrued PTO.
--
-- Marker column so this is always distinguishable from a real PTO request. There is
-- no PTO balance counter in the system today (time_off_check_eligibility explicitly
-- says "balance check not yet implemented"), but when one is built it MUST exclude
-- rows where derived_from_holiday_id IS NOT NULL, or the handbook's "in addition to
-- their normal accrued PTO" is violated.

ALTER TABLE public.time_off_requests
  ADD COLUMN IF NOT EXISTS derived_from_holiday_id uuid
  REFERENCES public.company_holidays(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.time_off_requests.derived_from_holiday_id IS
  'Set when this row was auto-generated from a company_holidays closed day (Account Associate paid holiday per handbook). Any future PTO balance counter must EXCLUDE these rows — the handbook grants them in addition to accrued PTO.';

CREATE UNIQUE INDEX IF NOT EXISTS ux_tor_derived_holiday_person
  ON public.time_off_requests (requester_team_id, derived_from_holiday_id)
  WHERE derived_from_holiday_id IS NOT NULL;


CREATE OR REPLACE FUNCTION public.materialize_holiday_time_off_for_account_associates(
  p_agency_id uuid, p_from_date date DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_from       date := COALESCE(p_from_date, (now() AT TIME ZONE 'America/Chicago')::date);
  v_created    int := 0;
  v_skipped    int := 0;
  v_row        record;
BEGIN
  FOR v_row IN
    SELECT t.id AS team_member_id, t.first_name, h.id AS holiday_id,
           h.holiday_date, h.holiday_name
    FROM public.team t
    CROSS JOIN public.company_holidays h
    WHERE t.agency_id = p_agency_id
      AND t.is_active
      AND t.archived_at IS NULL
      AND COALESCE(t.is_admin_backoffice, false) = false
      AND t.role_level = 'Account Associate'
      AND t.employment_type = 'Full Time'
      AND h.agency_id = p_agency_id
      AND h.is_active
      AND h.observance = 'closed'
      -- "if it falls on a normal working day" — Mon-Fri only
      AND EXTRACT(isodow FROM h.holiday_date) BETWEEN 1 AND 5
      -- forward-looking only; never invent a past paid day
      AND h.holiday_date >= v_from
      -- "employed during these days"
      AND (t.hire_date IS NULL OR h.holiday_date >= t.hire_date)
  LOOP
    BEGIN
      INSERT INTO public.time_off_requests (
        agency_id, requester_team_id, request_type, start_date, end_date, partial_day,
        notes, status, is_paid, is_planned, submitted_at, decided_at, decision_note,
        derived_from_holiday_id,
        -- suppress the per-person notification email and the personal Google
        -- Calendar event: an agency-wide closure is not a personal time-off event.
        decision_notified_at, calendar_dispatched_at
      ) VALUES (
        p_agency_id, v_row.team_member_id, 'time_off_full_day',
        v_row.holiday_date, v_row.holiday_date, 'none',
        'Agency closed for ' || v_row.holiday_name
          || '. Paid holiday for full-time Account Associates per handbook Hours & Time Off. '
          || 'In addition to accrued PTO — does not count against balance.',
        'approved', true, true, now(), now(),
        'Auto-approved: company holiday', v_row.holiday_id,
        now(), now()
      );
      v_created := v_created + 1;
    EXCEPTION WHEN unique_violation THEN
      v_skipped := v_skipped + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object('from_date', v_from, 'created', v_created, 'skipped_existing', v_skipped);
END $function$;


-- Fold the Account Associate materialization into the same runner, so one
-- automation keeps both the holiday table and the entitlement rows current.
CREATE OR REPLACE FUNCTION public.seed_company_holidays_runner(
  p_agency_id uuid, p_recipe_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_year int := EXTRACT(year FROM (now() AT TIME ZONE 'America/Chicago'))::int;
  v_this jsonb;
  v_next jsonb;
  v_aa   jsonb;
  v_total int;
BEGIN
  v_this := public.seed_company_holidays(p_agency_id, v_year);
  v_next := public.seed_company_holidays(p_agency_id, v_year + 1);
  v_aa   := public.materialize_holiday_time_off_for_account_associates(p_agency_id);

  v_total := (v_this->>'inserted')::int + (v_this->>'updated')::int
           + (v_next->>'inserted')::int + (v_next->>'updated')::int
           + (v_aa->>'created')::int;

  RETURN jsonb_build_object(
    'records_processed', v_total,
    'output_summary', format(
      'Holidays: %s new / %s refreshed for %s, %s new / %s refreshed for %s. Account Associate paid holidays: %s created, %s already existed.',
      v_this->>'inserted', v_this->>'updated', v_year,
      v_next->>'inserted', v_next->>'updated', v_year + 1,
      v_aa->>'created', v_aa->>'skipped_existing'),
    'this_year', v_this,
    'next_year', v_next,
    'account_associate_holidays', v_aa
  );
END $function$;

GRANT EXECUTE ON FUNCTION public.materialize_holiday_time_off_for_account_associates(uuid, date) TO authenticated;


-- Register the automation. run_internal_recipe() dispatches any public function
-- taking (agency_id, recipe_id) and returning jsonb, so no edge function change is
-- needed. Monthly on the 1st: the seeder always writes the current year AND the
-- next one, so the table stays at least twelve months ahead and the job is
-- idempotent — a missed month self-heals on the following run.
INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
  timezone, composio_action, internal_handler, input_config, is_active
)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  'Company Holidays Seeder',
  'Seeds the current and next calendar year of handbook holidays into company_holidays, and materializes the paid-holiday time off full-time Account Associates are entitled to. Idempotent.',
  'cron', '0 6 1 * *', 'America/Chicago', 'INTERNAL',
  'seed_company_holidays_runner',
  '{"description": "Calls public.seed_company_holidays_runner(agency_id, recipe_id). Seeds current + next year, then materializes Account Associate paid holidays forward from today."}'::jsonb,
  true
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND internal_handler = 'seed_company_holidays_runner'
);
