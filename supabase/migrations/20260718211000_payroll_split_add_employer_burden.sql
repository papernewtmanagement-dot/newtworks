-- Fully-load the 12 pre-cutover payroll rows: gross + employer taxes.
-- Actuals from payroll_detail where present (5/22-6/26); 8% burden fallback earlier.
WITH per_row_loaded AS (
  SELECT
    pd.id AS detail_id,
    pr.pay_date,
    EXTRACT(YEAR FROM pr.pay_date)::int AS yr,
    EXTRACT(MONTH FROM pr.pay_date)::int AS mo,
    CASE
      WHEN t.role_level = 'Owner'
        OR COALESCE(t.is_admin_backoffice, false) = true
        OR t.business_entity_id = 'b1111111-1111-1111-1111-111111111111'::uuid
      THEN 'b1111111-1111-1111-1111-111111111111'::uuid
      ELSE 'b2222222-2222-2222-2222-222222222222'::uuid
    END AS entity_id,
    pd.gross_pay
      + COALESCE(pd.employer_taxes, ROUND(pd.gross_pay * 0.08, 2))
      AS fully_loaded_pay
  FROM payroll_runs pr
  JOIN payroll_detail pd ON pd.payroll_run_id = pr.id
  JOIN team t ON t.id = pd.team_member_id
  WHERE pr.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND pr.pay_date >= '2026-01-01'
    AND pr.pay_date < '2026-07-01'
),
per_month AS (
  SELECT yr, mo, entity_id, ROUND(SUM(fully_loaded_pay), 2) AS amt
  FROM per_row_loaded
  GROUP BY yr, mo, entity_id
)
UPDATE prior_year_pl pyp
SET amount = pm.amt, imported_at = NOW()
FROM per_month pm
WHERE pyp.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND pyp.period_year = pm.yr
  AND pyp.period_month = pm.mo
  AND pyp.business_entity_id = pm.entity_id
  AND pyp.account_name = '6005 Payroll Costs';
