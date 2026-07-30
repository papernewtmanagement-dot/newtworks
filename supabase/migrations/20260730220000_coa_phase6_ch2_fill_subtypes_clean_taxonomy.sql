-- Phase 6 Chunk 2 — fill NULL account_subtype + clean dirty descriptive subtype values
-- Prep step before the report-layer rebuild. New subtotal grouping keys off account_subtype
-- so every active COA needs a clean, canonical value.
--
-- Uses ROW-LEVEL matching on (business_entity_id, account_code) — the partial UNIQUE index
-- uq_chart_of_accounts_active_entity_code (WHERE is_active=true) guarantees each pair
-- resolves to exactly one active row.

-- 1) ASSETS — 5 rows
UPDATE public.chart_of_accounts SET account_subtype='suspense'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND is_active=true AND account_code='0005'
  AND business_entity_id='b2222222-2222-2222-2222-222222222222'
  AND account_subtype IS NULL;

UPDATE public.chart_of_accounts SET account_subtype='bank'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND is_active=true AND account_code='1011'
  AND business_entity_id='b2222222-2222-2222-2222-222222222222'
  AND account_subtype IS NULL;

UPDATE public.chart_of_accounts SET account_subtype='bank'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND is_active=true AND account_code='1012'
  AND business_entity_id='b2222222-2222-2222-2222-222222222222'
  AND account_subtype IS NULL;

UPDATE public.chart_of_accounts SET account_subtype='cash'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND is_active=true AND account_code='1040'
  AND business_entity_id='b2222222-2222-2222-2222-222222222222'
  AND account_subtype IS NULL;

-- HSA at Fidelity is invested for growth; distinguishes from transactional bank/cash on BS.
-- New subtype value on asset — first row with `investment` on asset side.
UPDATE public.chart_of_accounts SET account_subtype='investment'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND is_active=true AND account_code='1400'
  AND business_entity_id='b3333333-3333-3333-3333-333333333333'
  AND account_subtype IS NULL;

-- 2) EXPENSES — 6 rows
-- Four *Unclassified Expense — Business (0003) rows across PN, PSS, Eriosto, Steward
UPDATE public.chart_of_accounts SET account_subtype='suspense'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND is_active=true AND account_code='0003'
  AND account_type='expense'
  AND account_subtype IS NULL
  AND business_entity_id IN (
    'b1111111-1111-1111-1111-111111111111',
    'b2222222-2222-2222-2222-222222222222',
    'b4444444-4444-4444-4444-444444444444',
    'b5555555-5555-5555-5555-555555555555'
  );

UPDATE public.chart_of_accounts SET account_subtype='family'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND is_active=true AND account_code='9250'
  AND business_entity_id='b3333333-3333-3333-3333-333333333333'
  AND account_subtype IS NULL;

UPDATE public.chart_of_accounts SET account_subtype='contra_expense'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND is_active=true AND account_code='9820'
  AND business_entity_id='b3333333-3333-3333-3333-333333333333'
  AND account_subtype IS NULL;

-- 3) INCOMES — 2 rows
-- New subtype value on income — first `suspense` on income (parallel to expense `suspense`).
UPDATE public.chart_of_accounts SET account_subtype='suspense'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND is_active=true AND account_code='0002'
  AND business_entity_id='b2222222-2222-2222-2222-222222222222'
  AND account_subtype IS NULL;

UPDATE public.chart_of_accounts SET account_subtype='other'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND is_active=true AND account_code='8600'
  AND business_entity_id='b3333333-3333-3333-3333-333333333333'
  AND account_subtype IS NULL;

-- 4) LIABILITIES — 4 rows (all credit cards)
UPDATE public.chart_of_accounts SET account_subtype='credit_card'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND is_active=true
  AND account_code IN ('2110','2114','2115')
  AND business_entity_id='b2222222-2222-2222-2222-222222222222'
  AND account_subtype IS NULL;

UPDATE public.chart_of_accounts SET account_subtype='credit_card'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND is_active=true AND account_code='2141'
  AND business_entity_id='b1111111-1111-1111-1111-111111111111'
  AND account_subtype IS NULL;

-- 5) CLEANUP — 2 rows with descriptive notes stuffed into the subtype field.
-- Trim to canonical labels. No notes column on chart_of_accounts to preserve the descriptions;
-- context lives in prior session_notes/persistent_memory.
UPDATE public.chart_of_accounts SET account_subtype='intercompany_receivable'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND account_subtype LIKE 'intercompany_receivable;%';

UPDATE public.chart_of_accounts SET account_subtype='intercompany_payable'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND account_subtype LIKE 'intercompany_payable;%';

-- 6) STANDARDIZATION — Personal 3050 S-Corp Distributions currently has subtype `draw`.
-- PaperNewt sibling on the same account name uses `distribution`. S-Corp shareholder payouts
-- ARE distributions (`draw` is sole-prop language). Align to canonical `distribution`.
-- PaperNewt 3020 "Owner Draws" keeps `draws` — genuine draw account, distinct concept.
UPDATE public.chart_of_accounts SET account_subtype='distribution'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND is_active=true AND account_code='3050'
  AND business_entity_id='b3333333-3333-3333-3333-333333333333'
  AND account_subtype='draw';
