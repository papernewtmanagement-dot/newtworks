-- Drop dependent view, widen rate columns, recreate view
DROP VIEW IF EXISTS public.v_producer_roi_inputs;

ALTER TABLE public.agency 
  ALTER COLUMN smvc_rate_pc TYPE numeric(6,4),
  ALTER COLUMN blended_rate_other TYPE numeric(6,4),
  ALTER COLUMN lapse_rate_annual TYPE numeric(6,4);

CREATE OR REPLACE VIEW public.v_producer_roi_inputs AS
WITH cfg AS (
  SELECT agency.id AS agency_id,
    COALESCE(agency.smvc_rate_pc, 0.10) AS smvc_rate_pc,
    COALESCE(agency.blended_rate_other, 0.09) AS blended_rate_other,
    COALESCE(agency.lapse_rate_annual, 0.11) AS lapse_rate_annual,
    COALESCE(agency.payroll_burden_multiplier, 1.15) AS burden,
    agency.rates_are_defaults
  FROM agency
), team_cost AS (
  SELECT t.id AS team_member_id,
    t.agency_id,
    (t.first_name || ' '::text) || t.last_name AS producer_name,
    t.role,
    t.pay_type,
    t.pay_rate,
    t.pay_frequency,
    t.role_level,
    CASE lower(COALESCE(t.pay_frequency, 'weekly'::text))
      WHEN 'weekly'::text THEN t.pay_rate * 52::numeric
      WHEN 'biweekly'::text THEN t.pay_rate * 26::numeric
      WHEN 'semimonthly'::text THEN t.pay_rate * 24::numeric
      WHEN 'monthly'::text THEN t.pay_rate * 12::numeric
      WHEN 'annual'::text THEN t.pay_rate
      WHEN 'hourly'::text THEN t.pay_rate * 2080::numeric
      ELSE t.pay_rate * 52::numeric
    END AS annual_pay
  FROM team t
  WHERE t.is_active = true AND t.archived_at IS NULL AND t.category = 'agency'::text
), recent AS (
  SELECT pp.team_member_id,
    pp.agency_id,
    sum(pp.premium_issued) AS new_premium_3mo,
    sum(pp.premium_issued) / 3.0 AS new_premium_monthly_avg,
    count(DISTINCT (pp.period_year || '-'::text) || pp.period_month) AS months_counted
  FROM producer_production pp
  WHERE pp.premium_type = 'new'::text 
    AND make_date(pp.period_year, pp.period_month, 1) >= (date_trunc('month'::text, CURRENT_DATE::timestamp with time zone) - '3 mons'::interval)
  GROUP BY pp.team_member_id, pp.agency_id
)
SELECT tc.team_member_id,
  tc.agency_id,
  tc.producer_name,
  tc.role,
  tc.annual_pay,
  round(tc.annual_pay * cfg.burden, 2) AS fully_loaded_annual_cost,
  round(tc.annual_pay * cfg.burden / 12::numeric, 2) AS fully_loaded_monthly_cost,
  COALESCE(round(r.new_premium_monthly_avg, 2), 0::numeric) AS new_premium_monthly_avg,
  cfg.smvc_rate_pc,
  cfg.lapse_rate_annual,
  cfg.burden,
  cfg.rates_are_defaults,
  COALESCE(round(r.new_premium_monthly_avg * cfg.smvc_rate_pc, 2), 0::numeric) AS monthly_new_commission,
  COALESCE(round(r.new_premium_monthly_avg * 12::numeric * cfg.smvc_rate_pc * (1::numeric - cfg.lapse_rate_annual), 2), 0::numeric) AS yr1_renewal_commission_est,
  tc.role_level
FROM team_cost tc
  LEFT JOIN cfg ON cfg.agency_id = tc.agency_id
  LEFT JOIN recent r ON r.team_member_id = tc.team_member_id
WHERE tc.role = ANY (ARRAY['Acquisition'::text, 'Inside Sales'::text, 'Owner'::text]);

GRANT SELECT ON public.v_producer_roi_inputs TO anon, authenticated;
