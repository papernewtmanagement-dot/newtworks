-- 1. Archive flag
ALTER TABLE public.staff
  ADD COLUMN IF NOT EXISTS archived_at timestamptz NULL;

-- 2. role_level (Account Manager / Account Associate)
ALTER TABLE public.staff
  ADD COLUMN IF NOT EXISTS role_level text NULL;

ALTER TABLE public.staff
  DROP CONSTRAINT IF EXISTS staff_role_level_check;
ALTER TABLE public.staff
  ADD CONSTRAINT staff_role_level_check
  CHECK (role_level IS NULL OR role_level IN ('Account Manager','Account Associate'));

CREATE INDEX IF NOT EXISTS staff_role_level_idx  ON public.staff (role_level);
CREATE INDEX IF NOT EXISTS staff_archived_at_idx ON public.staff (archived_at);

-- 3. Archive the three outsourced support people
UPDATE public.staff
SET archived_at = NOW(),
    is_active = false,
    notes = COALESCE(notes, '') || ' [Archived 2026-06-11 — outsourced support, hidden from UI.]',
    updated_at = NOW()
WHERE first_name IN ('Lourdes','Anabel','Inez')
  AND last_name  IN ('Estrada','Sanchez','Garcia');

-- 4. Remap roles BEFORE adding CHECK constraint
UPDATE public.staff SET role = 'Acquisition',  updated_at = NOW() WHERE first_name = 'Thomas' AND last_name = 'Lynch';
UPDATE public.staff SET role = 'Inside Sales', role_level = 'Account Manager', updated_at = NOW() WHERE first_name = 'John'   AND last_name = 'Kostov';
UPDATE public.staff SET role = 'Inside Sales', role_level = 'Account Manager', updated_at = NOW() WHERE first_name = 'Jason'  AND last_name = 'Fuller';

-- 5. Lock the role vocabulary
ALTER TABLE public.staff
  DROP CONSTRAINT IF EXISTS staff_role_check;
ALTER TABLE public.staff
  ADD CONSTRAINT staff_role_check
  CHECK (role IS NULL OR role IN ('Acquisition','Inside Sales','Reception','Support','Owner'));

-- 6. Update v_producer_roi_inputs: filter on new role names, append role_level at the end
CREATE OR REPLACE VIEW public.v_producer_roi_inputs AS
 WITH cfg AS (
   SELECT agency.id AS agency_id,
          COALESCE(agency.smvc_rate_pc, 0.10) AS smvc_rate_pc,
          COALESCE(agency.blended_rate_other, 0.09) AS blended_rate_other,
          COALESCE(agency.lapse_rate_annual, 0.11) AS lapse_rate_annual,
          COALESCE(agency.payroll_burden_multiplier, 1.15) AS burden,
          agency.rates_are_defaults
   FROM agency
 ), staff_cost AS (
   SELECT s.id AS staff_id,
          s.agency_id,
          (s.first_name || ' ') || s.last_name AS producer_name,
          s.role,
          s.pay_type,
          s.pay_rate,
          s.pay_frequency,
          s.role_level,
          CASE lower(COALESCE(s.pay_frequency, 'weekly'))
              WHEN 'weekly'       THEN s.pay_rate * 52
              WHEN 'biweekly'     THEN s.pay_rate * 26
              WHEN 'semimonthly'  THEN s.pay_rate * 24
              WHEN 'monthly'      THEN s.pay_rate * 12
              WHEN 'annual'       THEN s.pay_rate
              WHEN 'hourly'       THEN s.pay_rate * 2080
              ELSE s.pay_rate * 52
          END AS annual_pay
   FROM staff s
   WHERE s.is_active = true
     AND s.archived_at IS NULL
     AND s.category = 'agency'
 ), recent AS (
   SELECT pp.staff_id,
          pp.agency_id,
          sum(pp.premium_issued) AS new_premium_3mo,
          sum(pp.premium_issued) / 3.0 AS new_premium_monthly_avg,
          count(DISTINCT (pp.period_year || '-') || pp.period_month) AS months_counted
   FROM producer_production pp
   WHERE pp.premium_type = 'new'
     AND make_date(pp.period_year, pp.period_month, 1) >= (date_trunc('month', CURRENT_DATE::timestamp) - interval '3 mons')
   GROUP BY pp.staff_id, pp.agency_id
 )
 SELECT sc.staff_id,
        sc.agency_id,
        sc.producer_name,
        sc.role,
        sc.annual_pay,
        round(sc.annual_pay * cfg.burden, 2) AS fully_loaded_annual_cost,
        round(sc.annual_pay * cfg.burden / 12, 2) AS fully_loaded_monthly_cost,
        COALESCE(round(r.new_premium_monthly_avg, 2), 0) AS new_premium_monthly_avg,
        cfg.smvc_rate_pc,
        cfg.lapse_rate_annual,
        cfg.burden,
        cfg.rates_are_defaults,
        COALESCE(round(r.new_premium_monthly_avg * cfg.smvc_rate_pc, 2), 0) AS monthly_new_commission,
        COALESCE(round(r.new_premium_monthly_avg * 12 * cfg.smvc_rate_pc * (1 - cfg.lapse_rate_annual), 2), 0) AS yr1_renewal_commission_est,
        sc.role_level
 FROM staff_cost sc
 LEFT JOIN cfg    ON cfg.agency_id = sc.agency_id
 LEFT JOIN recent r ON r.staff_id  = sc.staff_id
 WHERE sc.role IN ('Acquisition','Inside Sales','Owner');
