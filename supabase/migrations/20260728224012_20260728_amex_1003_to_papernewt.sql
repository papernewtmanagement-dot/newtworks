-- Move AMEX card ending in 1003 (AMEX - Discretionary, COA-009)
-- from Peter Story State Farm (b2222222) to PaperNewt LLC (b1111111).
--
-- Peter directive 2026-07-28: this is a PaperNewt card. Card must show on
-- PaperNewt in the credit-card tab, and its individual transactions must
-- land in the PaperNewt layer of the P&L (as PaperNewt-own lines, not
-- rolled up from Peter Story State Farm).
--
-- Scope of move (6 tables, entity-scoped per financial hierarchy rule):
--   chart_of_accounts    id  9033ef5b-8ecd-4403-83c9-6331381d86cb  (COA-009)
--   credit_accounts      id  3dacdd99-49b1-49f7-8bcf-50fcc0e992c0
--   opening_balances     id  ea88782d-071f-4bcf-a19a-f2009614cd5c  (COA-009 anchor)
--   credit_transactions  463 rows on credit_account_id = 3dacdd99
--   journal_entries      463 rows linked via credit_transactions.journal_entry_id
--   journal_lines        926 rows tied to those journal_entries

BEGIN;

-- 1. chart_of_accounts row (the account itself)
UPDATE public.chart_of_accounts
SET business_entity_id = 'b1111111-1111-1111-1111-111111111111'
WHERE id = '9033ef5b-8ecd-4403-83c9-6331381d86cb'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 2. credit_accounts row (the card record shown in Financials → Credit tab)
UPDATE public.credit_accounts
SET business_entity_id = 'b1111111-1111-1111-1111-111111111111'
WHERE id = '3dacdd99-49b1-49f7-8bcf-50fcc0e992c0'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 3. opening_balances anchor for COA-009 on 6/30/2026 cutover
UPDATE public.opening_balances
SET business_entity_id = 'b1111111-1111-1111-1111-111111111111'
WHERE id = 'ea88782d-071f-4bcf-a19a-f2009614cd5c'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 4. credit_transactions (463 rows)
UPDATE public.credit_transactions
SET business_entity_id = 'b1111111-1111-1111-1111-111111111111'
WHERE credit_account_id = '3dacdd99-49b1-49f7-8bcf-50fcc0e992c0'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 5. journal_entries linked to those credit_transactions (463 rows)
UPDATE public.journal_entries je
SET business_entity_id = 'b1111111-1111-1111-1111-111111111111'
FROM public.credit_transactions ct
WHERE ct.journal_entry_id = je.id
  AND ct.credit_account_id = '3dacdd99-49b1-49f7-8bcf-50fcc0e992c0'
  AND je.agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 6. journal_lines for those journal_entries (926 rows)
UPDATE public.journal_lines jl
SET business_entity_id = 'b1111111-1111-1111-1111-111111111111'
FROM public.credit_transactions ct
WHERE ct.journal_entry_id = jl.journal_entry_id
  AND ct.credit_account_id = '3dacdd99-49b1-49f7-8bcf-50fcc0e992c0'
  AND jl.agency_id = '126794dd-25ff-47d2-a436-724499733365';

COMMIT;
