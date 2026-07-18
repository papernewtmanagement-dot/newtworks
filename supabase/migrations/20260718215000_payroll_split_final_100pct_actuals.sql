-- Final rebuild: pre-cutover 2026 payroll split using 100% actual employer_taxes
-- Source: real SurePayroll XLS files (Jan 4 - May 15) + 6 mid-May-to-June runs already had actuals

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
    ROUND(SUM(pd.gross_pay + pd.employer_taxes), 2) AS amt
  FROM payroll_runs pr
  JOIN payroll_detail pd ON pd.payroll_run_id = pr.id
  JOIN team t ON t.id = pd.team_member_id
  WHERE pr.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND pr.pay_date >= '2026-01-01'
    AND pr.pay_date < '2026-07-01'
  GROUP BY 1, 2, 3
)
UPDATE prior_year_pl pyp
SET amount = pm.amt, imported_at = NOW()
FROM per_month pm
WHERE pyp.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND pyp.period_year = pm.yr
  AND pyp.period_month = pm.mo
  AND pyp.business_entity_id = pm.entity_id
  AND pyp.account_name = '6005 Payroll Costs';
