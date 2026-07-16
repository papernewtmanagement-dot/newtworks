-- Financials 6/30/2026 re-anchor migration
-- Purpose: seat real 6/30 statement balances into opening_balances, refactor
-- v_bank_balances + v_card_balances to layer opening_balances underneath JE
-- activity, clean up stale bank/credit stored balances and inactive accounts.
-- Per OQ 80725dd0. Peter approved 2026-07-16.

-- ============================================================================
-- 1. Seed opening_balances rows at as_of_date = 2026-06-30 (gl_anchor_date)
-- ============================================================================

INSERT INTO public.opening_balances
  (agency_id, business_entity_id, as_of_date, account_code, account_name, account_type, opening_balance, source)
VALUES
  -- Asset: US Bank Income (3977) — statement balance
  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'b1111111-1111-1111-1111-111111111111'::uuid,
   '2026-06-30', 'COA-007', 'US Bank - Income', 'asset', 30034.83,
   '6_30_2026_statement'),
  -- Liability: Chase Mktg 1 (7762 Peter) — empty half of consolidated pair
  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'b1111111-1111-1111-1111-111111111111'::uuid,
   '2026-06-30', 'COA-011', 'Chase - Marketing 1', 'liability', 0.00,
   '6_30_2026_statement'),
  -- Liability: Chase Mktg 2 (7770 Marie) — real consolidated balance
  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'b1111111-1111-1111-1111-111111111111'::uuid,
   '2026-06-30', 'COA-012', 'Chase - Marketing 2', 'liability', 3923.55,
   '6_30_2026_statement'),
  -- Liability: CITI PaperNewt (1247)
  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'b1111111-1111-1111-1111-111111111111'::uuid,
   '2026-06-30', 'COA-028', 'CITI Personal Card', 'liability', 442.10,
   '6_30_2026_statement'),
  -- Liability: Cap One Personal (7435)
  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'b1111111-1111-1111-1111-111111111111'::uuid,
   '2026-06-30', 'COA-010', 'Capital One Personal Card', 'liability', 1918.78,
   '6_30_2026_statement');

-- ============================================================================
-- 2. Update bank_accounts stored balances
-- ============================================================================

UPDATE public.bank_accounts
SET current_balance = 30034.83, as_of_date = '2026-06-30', updated_at = NOW()
WHERE id = '723bea83-bcae-4f9b-9997-f9e67bc62e2d'::uuid;  -- US Bank Income

UPDATE public.bank_accounts
SET current_balance = NULL, as_of_date = NULL, updated_at = NOW()
WHERE id = '4dc792cf-c087-47f9-b9ea-cbf1c43421f6'::uuid;  -- US Bank Expenses (awaiting Jun stmt)

UPDATE public.bank_accounts
SET is_active = false, updated_at = NOW()
WHERE id IN (
  '256711ee-e8c7-4a4c-90c1-410732b67822'::uuid,  -- TRB Discretionary
  '667021f4-e104-4ef8-af43-d9ecda299c7e'::uuid,  -- TRB Expenses
  '5c97d22f-95a9-4e41-be20-70fc6e320b2f'::uuid,  -- TRB Income
  '31387586-5bf9-4311-8128-141e0d4fa377'::uuid   -- TRB Marketing
);

DELETE FROM public.bank_accounts
WHERE id = '2894f0ee-4434-4b0a-b5f7-56189414da05'::uuid;  -- Cash on Hand (prior-books plug)

-- ============================================================================
-- 3. Update credit_accounts stored balances
-- ============================================================================

UPDATE public.credit_accounts
SET current_balance = 0.00, updated_at = NOW()
WHERE id = '37c0a92a-66b8-42d4-a602-cd36734f375f'::uuid;  -- Chase Mktg 1 (7762 Peter)

UPDATE public.credit_accounts
SET current_balance = 3923.55, updated_at = NOW()
WHERE id = '4d1af9e2-dff4-4a48-aec5-5c13ed7a5205'::uuid;  -- Chase Mktg 2 (7770 Marie)

UPDATE public.credit_accounts
SET current_balance = 442.10, updated_at = NOW()
WHERE id = 'b9af7f0c-06df-4e5a-9d93-9ac579d8f55e'::uuid;  -- CITI PaperNewt (1247)

UPDATE public.credit_accounts
SET current_balance = 1918.78, updated_at = NOW()
WHERE id = '0ed39c01-7280-446f-ab3b-a6e11e5e8cca'::uuid;  -- Cap One Personal (7435)

-- SF Card Alvi + SF Card Peter → DEFERRED to Aug SFFCU e-statement, no update.

-- ============================================================================
-- 4. Update account_starting_balances to 6/30 anchor
-- ============================================================================

UPDATE public.account_starting_balances
SET balance = 30034.83, as_of_date = '2026-06-30',
    source = '6_30_2026_statement',
    notes = 'Real bank statement balance from 6/30/26. Prior 4/30 book balance replaced.',
    updated_at = NOW()
WHERE id = 'a77b45c1-e826-4ce7-9869-628fb33b9ca3'::uuid;  -- 3977 US Bank Income

UPDATE public.account_starting_balances
SET balance = 0.00, as_of_date = '2026-06-30',
    source = 'awaiting_june_statement',
    notes = 'Peter directive 2026-07-16: US Bank Expenses is active but should not carry $171K balance. June statement not on hand — balance placeholder zeroed. Update when June US Bank Expenses statement arrives.',
    updated_at = NOW()
WHERE id = '3a421c72-8306-4aa0-b29f-1e10150aa696'::uuid;  -- 4335 US Bank Expenses

-- ============================================================================
-- 5. Refactor v_bank_balances to layer opening_balances under JE activity
-- ============================================================================

CREATE OR REPLACE VIEW public.v_bank_balances AS
WITH cfg AS (
  SELECT (setting_value)::date AS anchor_date
  FROM public.settings
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND setting_key = 'gl_anchor_date'
),
scope AS (
  SELECT unnest(ARRAY['COA-001','COA-002','COA-003','COA-004','COA-005','COA-006','COA-007','COA-024']::text[]) AS account_code
),
anchor AS (
  SELECT ob.account_code, ob.account_name, ob.opening_balance
  FROM public.opening_balances ob
  CROSS JOIN cfg
  WHERE ob.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND ob.as_of_date = cfg.anchor_date
    AND ob.account_code IN (SELECT account_code FROM scope)
),
ledger AS (
  SELECT je.agency_id,
         coa.id AS chart_account_id,
         coa.account_code,
         coa.account_name,
         ROUND(SUM(jl.debit) FILTER (WHERE je.entry_date > cfg.anchor_date)
             - SUM(jl.credit) FILTER (WHERE je.entry_date > cfg.anchor_date), 2)
             AS activity_since_anchor,
         MAX(je.entry_date) AS last_entry_date,
         COUNT(DISTINCT je.id) FILTER (WHERE je.entry_date > cfg.anchor_date) AS entry_count
  FROM public.journal_entries je
  JOIN public.journal_lines jl ON jl.journal_entry_id = je.id
  JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  CROSS JOIN cfg
  WHERE coa.account_code IN (SELECT account_code FROM scope)
  GROUP BY je.agency_id, coa.id, coa.account_code, coa.account_name
),
scoped AS (
  SELECT account_code FROM anchor
  UNION
  SELECT account_code FROM ledger
)
SELECT
  '126794dd-25ff-47d2-a436-724499733365'::uuid AS agency_id,
  l.chart_account_id,
  s.account_code,
  COALESCE(l.account_name, a.account_name) AS account_name,
  COALESCE(a.opening_balance, 0::numeric) AS balance_anchor,
  COALESCE(l.activity_since_anchor, 0::numeric) AS activity_since_anchor,
  ROUND(COALESCE(a.opening_balance, 0) + COALESCE(l.activity_since_anchor, 0), 2)
    AS current_balance_derived,
  l.last_entry_date,
  COALESCE(l.entry_count, 0) AS entry_count,
  (COALESCE(a.opening_balance, 0) + COALESCE(l.activity_since_anchor, 0) < 0)
    AS needs_review
FROM scoped s
LEFT JOIN anchor a ON a.account_code = s.account_code
LEFT JOIN ledger l ON l.account_code = s.account_code;

-- ============================================================================
-- 6. Refactor v_card_balances to layer opening_balances under JE activity
-- ============================================================================

CREATE OR REPLACE VIEW public.v_card_balances AS
WITH cfg AS (
  SELECT (setting_value)::date AS anchor_date
  FROM public.settings
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND setting_key = 'gl_anchor_date'
),
scope AS (
  SELECT ca.id AS credit_account_id,
         ca.account_name AS ca_name,
         ca.institution,
         ca.chart_account_id,
         coa.account_code,
         coa.account_name AS coa_name
  FROM public.credit_accounts ca
  JOIN public.chart_of_accounts coa ON coa.id = ca.chart_account_id
  WHERE ca.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
),
anchor AS (
  SELECT ob.account_code, ob.opening_balance
  FROM public.opening_balances ob
  CROSS JOIN cfg
  WHERE ob.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND ob.as_of_date = cfg.anchor_date
    AND ob.account_code IN (SELECT account_code FROM scope)
),
ledger AS (
  SELECT je.agency_id,
         s.credit_account_id,
         s.chart_account_id,
         s.account_code,
         ROUND(SUM(jl.debit) FILTER (WHERE je.entry_date > cfg.anchor_date)
             - SUM(jl.credit) FILTER (WHERE je.entry_date > cfg.anchor_date), 2)
             AS activity_since_anchor,
         MAX(je.entry_date) AS last_entry_date,
         COUNT(DISTINCT je.id) FILTER (WHERE je.entry_date > cfg.anchor_date) AS entry_count
  FROM public.journal_entries je
  JOIN public.journal_lines jl ON jl.journal_entry_id = je.id
  JOIN scope s ON s.chart_account_id = jl.account_id
  CROSS JOIN cfg
  GROUP BY je.agency_id, s.credit_account_id, s.chart_account_id, s.account_code
)
SELECT
  '126794dd-25ff-47d2-a436-724499733365'::uuid AS agency_id,
  s.credit_account_id,
  s.ca_name AS account_name,
  s.institution,
  s.chart_account_id,
  COALESCE(a.opening_balance, 0::numeric) AS balance_anchor,
  COALESCE(l.activity_since_anchor, 0::numeric) AS activity_since_anchor,
  ROUND(COALESCE(a.opening_balance, 0) + COALESCE(l.activity_since_anchor, 0), 2)
    AS current_balance_derived,
  l.last_entry_date,
  COALESCE(l.entry_count, 0) AS entry_count,
  (COALESCE(a.opening_balance, 0) + COALESCE(l.activity_since_anchor, 0) < 0)
    AS needs_review
FROM scope s
LEFT JOIN anchor a ON a.account_code = s.account_code
LEFT JOIN ledger l ON l.credit_account_id = s.credit_account_id;

COMMENT ON VIEW public.v_bank_balances IS
  'Bank account balances anchored to opening_balances at gl_anchor_date (6/30/2026) '
  'plus post-anchor JE activity. Refactored 2026-07-16 (Financials 6/30 re-anchor).';

COMMENT ON VIEW public.v_card_balances IS
  'Credit card balances anchored to opening_balances at gl_anchor_date (6/30/2026) '
  'plus post-anchor JE activity. Refactored 2026-07-16 (Financials 6/30 re-anchor).';
