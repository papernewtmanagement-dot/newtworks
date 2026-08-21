-- ============================================================
-- PRODUCER ROI SUMMARY VIEW
-- Per producer: current new-premium run-rate, the commission it
-- generates at the agency's SMVC rate, fully-loaded payroll cost,
-- and the inputs the app needs to project the renewal-tail
-- break-even month. One row per producer (P&C-focused).
-- ============================================================
CREATE OR REPLACE VIEW v_producer_roi_inputs AS
WITH cfg AS (
  SELECT id AS agency_id,
         COALESCE(smvc_rate_pc, 0.10)            AS smvc_rate_pc,
         COALESCE(blended_rate_other, 0.09)      AS blended_rate_other,
         COALESCE(lapse_rate_annual, 0.11)       AS lapse_rate_annual,
         COALESCE(payroll_burden_multiplier,1.15) AS burden,
         rates_are_defaults
  FROM agency
),
-- annualize each staffer's pay by frequency, apply burden
staff_cost AS (
  SELECT s.id AS staff_id, s.agency_id,
         s.first_name || ' ' || s.last_name AS producer_name,
         s.role, s.pay_type, s.pay_rate, s.pay_frequency,
         CASE lower(COALESCE(s.pay_frequency,'weekly'))
           WHEN 'weekly'      THEN s.pay_rate * 52
           WHEN 'biweekly'    THEN s.pay_rate * 26
           WHEN 'semimonthly' THEN s.pay_rate * 24
           WHEN 'monthly'     THEN s.pay_rate * 12
           WHEN 'annual'      THEN s.pay_rate
           WHEN 'hourly'      THEN s.pay_rate * 2080
           ELSE s.pay_rate * 52
         END AS annual_pay
  FROM staff s
  WHERE s.is_active = true
),
-- latest 3 months of NEW premium per producer = rolling run-rate
recent AS (
  SELECT pp.staff_id, pp.agency_id,
         SUM(pp.premium_issued)                              AS new_premium_3mo,
         SUM(pp.premium_issued)/3.0                          AS new_premium_monthly_avg,
         COUNT(DISTINCT (pp.period_year||'-'||pp.period_month)) AS months_counted
  FROM producer_production pp
  WHERE pp.premium_type = 'new'
    AND make_date(pp.period_year, pp.period_month, 1)
        >= (date_trunc('month', CURRENT_DATE) - interval '3 months')
  GROUP BY pp.staff_id, pp.agency_id
)
SELECT
  sc.staff_id,
  sc.agency_id,
  sc.producer_name,
  sc.role,
  sc.annual_pay,
  ROUND(sc.annual_pay * cfg.burden, 2)                       AS fully_loaded_annual_cost,
  ROUND(sc.annual_pay * cfg.burden / 12, 2)                  AS fully_loaded_monthly_cost,
  COALESCE(ROUND(r.new_premium_monthly_avg, 2), 0)           AS new_premium_monthly_avg,
  cfg.smvc_rate_pc,
  cfg.lapse_rate_annual,
  cfg.burden,
  cfg.rates_are_defaults,
  -- monthly NEW-business commission at the SMVC P&C rate
  COALESCE(ROUND(r.new_premium_monthly_avg * cfg.smvc_rate_pc, 2), 0)
                                                             AS monthly_new_commission,
  -- annualized renewal value of one year of this run-rate, after one lapse cycle
  COALESCE(ROUND(r.new_premium_monthly_avg * 12 * cfg.smvc_rate_pc * (1 - cfg.lapse_rate_annual), 2), 0)
                                                             AS yr1_renewal_commission_est
FROM staff_cost sc
LEFT JOIN cfg ON cfg.agency_id = sc.agency_id
LEFT JOIN recent r ON r.staff_id = sc.staff_id
WHERE sc.role IN ('Producer','Account Manager','Owner');
