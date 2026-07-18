-- Rebuild pre-cutover 2026 payroll in prior_year_pl with Plan A entity split
-- Source of truth: payroll_detail (per-person gross_pay per run)
-- Split rule (mirrors payroll_gl_writer Plan A):
--   Peter (Owner) + Leslie (business_entity_id=PN) => PaperNewt LLC (b1111111)
--   Everyone else => Peter Story State Farm (b2222222)
-- Bucketing: calendar month of pay_date (cash basis)

-- 1) Remove existing 2026 Jan-Jun payroll representation on agency
DELETE FROM prior_year_pl
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND period_year = 2026
  AND period_month BETWEEN 1 AND 6
  AND account_name IN ('6005 Payroll Costs', 'GP Peter', 'GP Leslie');

-- 2) Insert clean per-entity per-month rows from payroll_detail
--    period_start/period_end are GENERATED — omit from INSERT
WITH per_month AS (
  SELECT
    EXTRACT(YEAR FROM pr.pay_date)::int AS yr,
    EXTRACT(MONTH FROM pr.pay_date)::int AS mo,
    CASE
      WHEN t.role_level = 'Owner'
        OR COALESCE(t.is_admin_backoffice, false) = true
        OR t.business_entity_id = 'b1111111-1111-1111-1111-111111111111'::uuid
      THEN 'b1111111-1111-1111-1111-111111111111'::uuid
      ELSE 'b2222222-2222-2222-2222-222222222222'::uuid
    END AS entity_id,
    SUM(pd.gross_pay) AS amt
  FROM payroll_runs pr
  JOIN payroll_detail pd ON pd.payroll_run_id = pr.id
  JOIN team t ON t.id = pd.team_member_id
  WHERE pr.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND pr.pay_date >= '2026-01-01'
    AND pr.pay_date < '2026-07-01'
  GROUP BY 1, 2, 3
)
INSERT INTO prior_year_pl (
  agency_id, business_entity_id,
  period_year, period_month,
  section, section_type, account_name, amount,
  source_entity, imported_at
)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  pm.entity_id,
  pm.yr,
  pm.mo,
  '0002 TEAM',
  'Expense',
  '6005 Payroll Costs',
  ROUND(pm.amt, 2),
  CASE WHEN pm.entity_id = 'b1111111-1111-1111-1111-111111111111'::uuid
       THEN 'PaperNewt LLC'
       ELSE 'Peter Story State Farm' END,
  NOW()
FROM per_month pm
ORDER BY pm.yr, pm.mo, pm.entity_id;
