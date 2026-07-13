-- Consolidation: move snapshot fields from team_weekly_snapshot onto
-- weekly_cpr_team_detail. One row per person per week already exists there;
-- denormalizing collocates data with residual_pool_diag JSONB pattern.
--
-- Peter directive 2026-07-13 pm5: "wouldn't [weekly_cpr_team_detail] be the
-- best place to just include their role category, base pay, etc?"

ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS role text,
  ADD COLUMN IF NOT EXISTS role_level text,
  ADD COLUMN IF NOT EXISTS role_category text,
  ADD COLUMN IF NOT EXISTS category text,
  ADD COLUMN IF NOT EXISTS first_name text,
  ADD COLUMN IF NOT EXISTS last_name text,
  ADD COLUMN IF NOT EXISTS nickname text,
  ADD COLUMN IF NOT EXISTS is_active boolean,
  ADD COLUMN IF NOT EXISTS archived_at timestamptz,
  ADD COLUMN IF NOT EXISTS is_admin_backoffice boolean,
  ADD COLUMN IF NOT EXISTS is_test_user boolean,
  ADD COLUMN IF NOT EXISTS start_date date,
  ADD COLUMN IF NOT EXISTS end_date date,
  ADD COLUMN IF NOT EXISTS hire_date date,
  ADD COLUMN IF NOT EXISTS pay_type text,
  ADD COLUMN IF NOT EXISTS pay_rate numeric,
  ADD COLUMN IF NOT EXISTS pay_frequency text,
  ADD COLUMN IF NOT EXISTS annual_benefits_value numeric,
  ADD COLUMN IF NOT EXISTS weekly_life_benefit_agency_paid numeric,
  ADD COLUMN IF NOT EXISTS weekly_health_benefit_agency_paid numeric,
  ADD COLUMN IF NOT EXISTS work_location text,
  ADD COLUMN IF NOT EXISTS license_pc boolean,
  ADD COLUMN IF NOT EXISTS license_lh boolean,
  ADD COLUMN IF NOT EXISTS license_ips boolean;

WITH src AS (
  SELECT d.id AS detail_id,
         s.role, s.role_level, s.role_category, s.category,
         s.first_name, s.last_name, s.nickname,
         s.is_active, s.archived_at, s.is_admin_backoffice, s.is_test_user,
         s.start_date, s.end_date, s.hire_date,
         s.pay_type, s.pay_rate, s.pay_frequency,
         s.annual_benefits_value,
         s.weekly_life_benefit_agency_paid, s.weekly_health_benefit_agency_paid,
         s.work_location
  FROM public.weekly_cpr_team_detail d
  JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
  JOIN public.team_weekly_snapshot s
    ON s.team_member_id   = d.team_member_id
   AND s.agency_id        = r.agency_id
   AND s.week_ending_date = r.week_ending_date
)
UPDATE public.weekly_cpr_team_detail d
SET role                              = src.role,
    role_level                        = src.role_level,
    role_category                     = src.role_category,
    category                          = src.category,
    first_name                        = src.first_name,
    last_name                         = src.last_name,
    nickname                          = src.nickname,
    is_active                         = src.is_active,
    archived_at                       = src.archived_at,
    is_admin_backoffice               = src.is_admin_backoffice,
    is_test_user                      = src.is_test_user,
    start_date                        = src.start_date,
    end_date                          = src.end_date,
    hire_date                         = src.hire_date,
    pay_type                          = src.pay_type,
    pay_rate                          = src.pay_rate,
    pay_frequency                     = src.pay_frequency,
    annual_benefits_value             = src.annual_benefits_value,
    weekly_life_benefit_agency_paid   = src.weekly_life_benefit_agency_paid,
    weekly_health_benefit_agency_paid = src.weekly_health_benefit_agency_paid,
    work_location                     = src.work_location
FROM src
WHERE d.id = src.detail_id;

UPDATE public.weekly_cpr_team_detail d
SET license_pc  = t.license_pc,
    license_lh  = t.license_lh,
    license_ips = t.license_ips
FROM public.team t
WHERE t.id = d.team_member_id
  AND d.license_pc IS NULL;

CREATE OR REPLACE FUNCTION public.snapshot_team_on_weekly_cpr_team_detail_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.role IS NULL AND NEW.role_level IS NULL AND NEW.pay_type IS NULL THEN
    SELECT
      t.role, t.role_level, t.role_category, t.category,
      t.first_name, t.last_name, t.nickname,
      t.is_active, t.archived_at, t.is_admin_backoffice, t.is_test_user,
      t.start_date, t.end_date, t.hire_date,
      t.pay_type, t.pay_rate, t.pay_frequency,
      t.annual_benefits_value,
      t.weekly_life_benefit_agency_paid, t.weekly_health_benefit_agency_paid,
      t.work_location,
      t.license_pc, t.license_lh, t.license_ips
    INTO
      NEW.role, NEW.role_level, NEW.role_category, NEW.category,
      NEW.first_name, NEW.last_name, NEW.nickname,
      NEW.is_active, NEW.archived_at, NEW.is_admin_backoffice, NEW.is_test_user,
      NEW.start_date, NEW.end_date, NEW.hire_date,
      NEW.pay_type, NEW.pay_rate, NEW.pay_frequency,
      NEW.annual_benefits_value,
      NEW.weekly_life_benefit_agency_paid, NEW.weekly_health_benefit_agency_paid,
      NEW.work_location,
      NEW.license_pc, NEW.license_lh, NEW.license_ips
    FROM public.team t
    WHERE t.id = NEW.team_member_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_snapshot_team_on_weekly_cpr_team_detail_insert ON public.weekly_cpr_team_detail;
CREATE TRIGGER trg_snapshot_team_on_weekly_cpr_team_detail_insert
  BEFORE INSERT ON public.weekly_cpr_team_detail
  FOR EACH ROW EXECUTE FUNCTION public.snapshot_team_on_weekly_cpr_team_detail_insert();
