-- Personal Financials Phase 3 batch 3: 16 statements across 5 CCs
-- Reconciled per-cycle. Anchors moved back where new statements pre-date existing anchor.

-- 1. Anchor moves (4 shifts) + 1 new anchor for Discover 3208
UPDATE public.account_starting_balances SET as_of_date='2025-12-08', balance=639.71, updated_at=NOW(),
       notes=COALESCE(notes,'')||E'\n[pf3_batch3] anchor moved back from 2026-03-07 $536.48; 26-01 opens 12/09 with prev bal $639.71'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_type='credit_card' AND account_last4='8847';

UPDATE public.account_starting_balances SET as_of_date='2025-12-28', balance=2957.01, updated_at=NOW(),
       notes=COALESCE(notes,'')||E'\n[pf3_batch3] anchor moved back from 2026-03-28 $2165.58; 26-01 opens 12/29 with prev bal $2957.01'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_type='credit_card' AND account_last4='7435';

UPDATE public.account_starting_balances SET as_of_date='2026-02-15', balance=0.00, updated_at=NOW(),
       notes=COALESCE(notes,'')||E'\n[pf3_batch3] anchor moved back from 2026-04-17 -$493.01; 26-03 opens 2/16 with prev bal $0.00; 2/26 credit adj gives -$493.01'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_type='credit_card' AND account_last4='1006';

UPDATE public.account_starting_balances SET as_of_date='2025-12-04', balance=0.00, updated_at=NOW(),
       notes=COALESCE(notes,'')||E'\n[pf3_batch3] anchor moved back from 2026-04-06 $103.64; 26-01 opens 12/05 with prev bal $0.00'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_type='credit_card' AND account_last4='1247';

-- Discover Tithe 3208 has no prior anchor; INSERT new
INSERT INTO public.account_starting_balances
  (agency_id, account_last4, account_label, account_type, as_of_date, balance, source, notes, business_entity_id)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365', '3208', 'Discover Tithe CC ...3208', 'credit_card', '2025-12-27', 4688.82,
  'discover_statement', 'pf3_batch3: 26-01 opens 12/28/25 with prev bal $4688.82', 'b3333333-3333-3333-3333-333333333333'
);
