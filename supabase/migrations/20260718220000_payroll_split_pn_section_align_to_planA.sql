-- Align PN-side pre-cutover payroll section to match Q3 Plan A rendering.
-- Q3 JEs post to COA-PN-001 "Payroll Expense (PaperNewt)" which renders as its own P&L parent.
-- Change prior_year_pl PN payroll rows from section='0002 TEAM' to 'Payroll Expense (PaperNewt)'.
-- Agency side (b2222222) unchanged - already lands under 0002 TEAM which matches COA-020.
UPDATE prior_year_pl
SET section = 'Payroll Expense (PaperNewt)',
    imported_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND period_year = 2026
  AND period_month BETWEEN 1 AND 6
  AND business_entity_id = 'b1111111-1111-1111-1111-111111111111'::uuid
  AND account_name = '6005 Payroll Costs';
