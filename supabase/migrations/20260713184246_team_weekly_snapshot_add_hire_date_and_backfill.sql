
-- hire_date is stable (once set, doesn't drift), but include in snapshot 
-- for frontend join convenience. Add column, backfill from live team, 
-- extend trigger.

ALTER TABLE public.team_weekly_snapshot ADD COLUMN IF NOT EXISTS hire_date date;

UPDATE public.team_weekly_snapshot s
SET hire_date = t.hire_date
FROM public.team t
WHERE t.id = s.team_member_id
  AND s.hire_date IS NULL;

-- Extend the trigger to include hire_date on future INSERTs
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

