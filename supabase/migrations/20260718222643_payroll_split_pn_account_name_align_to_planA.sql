-- Collapse PN payroll subcategory: my prior_year_pl rows use account_name='6005 Payroll Costs'
-- but Q3 Plan A JEs post to COA-PN-001='Payroll Expense (PaperNewt)'. Match Q3.
UPDATE prior_year_pl
SET account_name = 'Payroll Expense (PaperNewt)',
    imported_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND period_year = 2026
  AND period_month BETWEEN 1 AND 6
  AND business_entity_id = 'b1111111-1111-1111-1111-111111111111'::uuid
  AND account_name = '6005 Payroll Costs';
