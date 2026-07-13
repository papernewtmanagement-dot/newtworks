-- team_weekly_snapshot: freezes end-of-week team state so historical CPRs
-- don't drift when live team fields change (promotions, role moves, benefits
-- adjustments, terminations, name updates).
--
-- Trigger fires on weekly_cpr_reports INSERT — mirrors the existing
-- required_sales_members_count snapshot pattern. Never overwrites on
-- re-run (ON CONFLICT DO NOTHING).
--
-- Peter directive 2026-07-13 pm5: Stephanie promoted today; last week's
-- CPR display + WtW math started reflecting promoted state retroactively.

CREATE TABLE IF NOT EXISTS public.team_weekly_snapshot (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id                 uuid NOT NULL REFERENCES public.agency(id),
  team_member_id            uuid NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,
  week_ending_date          date NOT NULL,
  first_name                text,
  last_name                 text,
  nickname                  text,
  role                      text,
  role_level                text,
  role_category             text,
  category                  text,
  is_active                 boolean,
  archived_at               timestamptz,
  is_admin_backoffice       boolean,
  is_test_user              boolean,
  start_date                date,
  end_date                  date,
  hire_date                 date,
  pay_type                  text,
  pay_rate                  numeric,
  pay_frequency             text,
  annual_benefits_value     numeric,
  weekly_life_benefit_agency_paid   numeric,
  weekly_health_benefit_agency_paid numeric,
  work_location             text,
  taken_at                  timestamptz NOT NULL DEFAULT now(),
  source                    text NOT NULL DEFAULT 'trigger',
  UNIQUE (agency_id, team_member_id, week_ending_date)
);

CREATE INDEX IF NOT EXISTS ix_team_weekly_snapshot_agency_week
  ON public.team_weekly_snapshot(agency_id, week_ending_date);
CREATE INDEX IF NOT EXISTS ix_team_weekly_snapshot_agency_person
  ON public.team_weekly_snapshot(agency_id, team_member_id);

ALTER TABLE public.team_weekly_snapshot ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS team_weekly_snapshot_agency_read ON public.team_weekly_snapshot;
CREATE POLICY team_weekly_snapshot_agency_read
  ON public.team_weekly_snapshot FOR SELECT TO authenticated
  USING (agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.id = auth.uid()));

DROP POLICY IF EXISTS team_weekly_snapshot_agency_all ON public.team_weekly_snapshot;
CREATE POLICY team_weekly_snapshot_agency_all
  ON public.team_weekly_snapshot FOR ALL TO authenticated
  USING (agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.id = auth.uid()))
  WITH CHECK (agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.id = auth.uid()));

CREATE OR REPLACE FUNCTION public.snapshot_team_on_weekly_cpr_reports_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  INSERT INTO public.team_weekly_snapshot (
    agency_id, team_member_id, week_ending_date,
    first_name, last_name, nickname,
    role, role_level, role_category, category,
    is_active, archived_at, is_admin_backoffice, is_test_user,
    start_date, end_date, hire_date,
    pay_type, pay_rate, pay_frequency,
    annual_benefits_value,
    weekly_life_benefit_agency_paid, weekly_health_benefit_agency_paid,
    work_location,
    source
  )
  SELECT
    t.agency_id, t.id, NEW.week_ending_date,
    t.first_name, t.last_name, t.nickname,
    t.role, t.role_level, t.role_category, t.category,
    t.is_active, t.archived_at, t.is_admin_backoffice, t.is_test_user,
    t.start_date, t.end_date, t.hire_date,
    t.pay_type, t.pay_rate, t.pay_frequency,
    t.annual_benefits_value,
    t.weekly_life_benefit_agency_paid, t.weekly_health_benefit_agency_paid,
    t.work_location,
    'trigger'
  FROM public.team t
  WHERE t.agency_id = NEW.agency_id
    AND (t.archived_at IS NULL OR t.archived_at > (NEW.week_ending_date - INTERVAL '6 days'))
  ON CONFLICT (agency_id, team_member_id, week_ending_date) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_snapshot_team_on_weekly_cpr_reports_insert ON public.weekly_cpr_reports;
CREATE TRIGGER trg_snapshot_team_on_weekly_cpr_reports_insert
  AFTER INSERT ON public.weekly_cpr_reports
  FOR EACH ROW EXECUTE FUNCTION public.snapshot_team_on_weekly_cpr_reports_insert();
