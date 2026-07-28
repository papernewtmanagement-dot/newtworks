-- Path B: US Bank 3447 collapse
-- Create new statement/billing credit_account for US Bank Business Cash Rewards 3447
-- with alternate_last4s=['4676','3439']; delete obsolete SF Card - Peter (4676) and
-- SF Card - Alvi (3439) credit_accounts + their statement_balances rows.
-- HELD: COA-013 + COA-014 chart_of_accounts (38 journal_lines on COA-014 stay put,
-- parallels Chase COA-011/COA-012 hold; tied to 241-JE pending workflow).

-- 1. New chart_of_accounts row
INSERT INTO public.chart_of_accounts (
  agency_id, account_code, account_name, account_type, account_subtype, business_entity_id
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'COA-036',
  'US Bank Business Cash Rewards 3447',
  'liability',
  'credit_card',
  'b2222222-2222-2222-2222-222222222222'
);

-- 2. New credit_account row
INSERT INTO public.credit_accounts (
  agency_id, account_name, institution, account_type,
  account_number_last4, alternate_last4s,
  business_entity_id, chart_account_id, is_active, current_balance
)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  'US Bank Business Cash Rewards 3447',
  'US Bank',
  'credit_card',
  '3447',
  ARRAY['4676','3439'],
  'b2222222-2222-2222-2222-222222222222',
  coa.id,
  true,
  0
FROM public.chart_of_accounts coa
WHERE coa.account_code = 'COA-036'
  AND coa.agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 3. Delete statement_balances on old COAs (will be repopulated by 3447 ingest)
DELETE FROM public.statement_balances
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND account_code IN ('COA-013','COA-014');

-- 4. Delete obsolete credit_accounts (0 credit_transactions on either, verified)
DELETE FROM public.credit_accounts
WHERE id IN (
  'c388951d-d8c2-4c76-9395-846502769475',  -- SF Card - Alvi 3439
  '8f3cb665-5437-42e7-a6d2-a2eaffcd914d'   -- SF Card - Peter 4676
);
