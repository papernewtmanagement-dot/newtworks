-- Refine pre-cutover payroll burden using per-person empirical rate from actual employer_taxes recorded 5/22-6/26.
-- Falls back to 8.5% (FICA 7.65 + FUTA 0.6 + SUTA 0.25) for team members who left before actuals were captured
-- and never had wage-base caps hit.

WITH per_person_burden AS (
  SELECT
    pd.team_member_id,
    SUM(pd.employer_taxes) / NULLIF(SUM(pd.gross_pay), 0) AS burden_rate
  FROM payroll_runs pr
  JOIN payroll_detail pd ON pd.payroll_run_id = pr.id
  WHERE pr.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND pd.employer_taxes IS NOT NULL
    AND pr.pay_date < '2026-07-01'
  GROUP BY pd.team_member_id
),
per_row_loaded AS (
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
    pd.gross_pay
      + COALESCE(
          pd.employer_taxes,                                     -- actuals when recorded
          ROUND(pd.gross_pay * ppb.burden_rate, 2),              -- per-person empirical
          ROUND(pd.gross_pay * 0.085, 2)                         -- 8.5% floor for departed low-earners
        ) AS fully_loaded_pay
  FROM payroll_runs pr
  JOIN payroll_detail pd ON pd.payroll_run_id = pr.id
  JOIN team t ON t.id = pd.team_member_id
  LEFT JOIN per_person_burden ppb ON ppb.team_member_id = pd.team_member_id
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
