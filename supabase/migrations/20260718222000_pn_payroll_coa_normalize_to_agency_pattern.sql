-- Normalize PaperNewt payroll COA to match agency pattern:
--   Parent: '0002 TEAM' (new)
--   Child:  '6005 Payroll Costs' (was 'Payroll Expense (PaperNewt)' with no parent)
-- Q3 Plan A JEs reference COA-PN-001 by account_code so ID/code stable; only account_name + parent change.

-- 1) Create the parent account for PN
INSERT INTO chart_of_accounts (id, agency_id, business_entity_id, account_code, account_name, account_type, account_subtype, parent_account_id, is_active, is_system, chart_namespace)
VALUES (
  gen_random_uuid(),
  '126794dd-25ff-47d2-a436-724499733365',
  'b1111111-1111-1111-1111-111111111111'::uuid,
  'COA-PN-020',
  '0002 TEAM',
  'expense',
  NULL,
  NULL,
  true,
  false,
  'papernewt'
)
ON CONFLICT DO NOTHING;

-- 2) Rename COA-PN-001 + attach to new parent
UPDATE chart_of_accounts
SET account_name = '6005 Payroll Costs',
    parent_account_id = (
      SELECT id FROM chart_of_accounts
      WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
        AND business_entity_id = 'b1111111-1111-1111-1111-111111111111'::uuid
        AND account_code = 'COA-PN-020'
    )
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND account_code = 'COA-PN-001';

-- 3) Revert prior_year_pl PN rows to the same standard shape
UPDATE prior_year_pl
SET section = '0002 TEAM',
    account_name = '6005 Payroll Costs',
    imported_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND period_year = 2026
  AND period_month BETWEEN 1 AND 6
  AND business_entity_id = 'b1111111-1111-1111-1111-111111111111'::uuid
  AND account_name = 'Payroll Expense (PaperNewt)';
