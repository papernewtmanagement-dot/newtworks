-- =====================================================================
-- Phase 4: Personal COA + JE backfill
-- =====================================================================
-- Establishes personal-side (b3333333) income/expense/equity/liability COAs
-- and posts a JE for each orphan bank_txn / credit_txn on the personal entity.
--
-- Classification policy (this migration):
--   - Bank txn description ILIKE 'Internet Banking Transfer%' -> other side
--     to PERSONAL-9990 Internal Transfers (equity, self-cancels on P&L)
--   - Everything else -> other side to PERSONAL-9999 Personal Suspense
--     (expense-type default, to be walked with Peter via classify_je_via_chat)
-- =====================================================================

DO $migration$
DECLARE
  v_agency_id      UUID := '126794dd-25ff-47d2-a436-724499733365';
  v_entity_id      UUID := 'b3333333-3333-3333-3333-333333333333';
  v_suspense_coa   UUID;
  v_transfer_coa   UUID;
  v_txn            RECORD;
  v_je_id          UUID;
  v_amt            NUMERIC;
  v_other_coa      UUID;
  v_cls_status     TEXT;
  v_bank_count     INT := 0;
  v_credit_count   INT := 0;
BEGIN

  -- 1. Personal COA rows (idempotent via ON CONFLICT)
  INSERT INTO public.chart_of_accounts
    (agency_id, business_entity_id, account_code, account_name, account_type, account_subtype, chart_namespace, is_active, is_system)
  VALUES
    -- INCOME (3)
    (v_agency_id, v_entity_id, 'PERSONAL-8100', 'Personal Wages',                'income',    'wages',        'active', true, false),
    (v_agency_id, v_entity_id, 'PERSONAL-8200', 'Interest & Investment Income',  'income',    'investment',   'active', true, false),
    (v_agency_id, v_entity_id, 'PERSONAL-8300', 'Other Personal Income',         'income',    'other',        'active', true, false),

    -- EXPENSES (17)
    (v_agency_id, v_entity_id, 'PERSONAL-9100', 'Housing',                       'expense',   'housing',      'active', true, false),
    (v_agency_id, v_entity_id, 'PERSONAL-9110', 'Home Utilities',                'expense',   'housing',      'active', true, false),
    (v_agency_id, v_entity_id, 'PERSONAL-9120', 'Home Maintenance',              'expense',   'housing',      'active', true, false),
    (v_agency_id, v_entity_id, 'PERSONAL-9200', 'Groceries',                     'expense',   'food',         'active', true, false),
    (v_agency_id, v_entity_id, 'PERSONAL-9210', 'Dining Out',                    'expense',   'food',         'active', true, false),
    (v_agency_id, v_entity_id, 'PERSONAL-9300', 'Auto Fuel',                     'expense',   'transport',    'active', true, false),
    (v_agency_id, v_entity_id, 'PERSONAL-9310', 'Auto Insurance',                'expense',   'transport',    'active', true, false),
    (v_agency_id, v_entity_id, 'PERSONAL-9320', 'Auto Maintenance',              'expense',   'transport',    'active', true, false),
    (v_agency_id, v_entity_id, 'PERSONAL-9400', 'Kids',                          'expense',   'family',       'active', true, false),
    (v_agency_id, v_entity_id, 'PERSONAL-9500', 'Medical & Health',              'expense',   'health',       'active', true, false),
    (v_agency_id, v_entity_id, 'PERSONAL-9600', 'Personal Insurance',            'expense',   'insurance',    'active', true, false),
    (v_agency_id, v_entity_id, 'PERSONAL-9610', 'Retirement & Savings',          'expense',   'financial',    'active', true, false),
    (v_agency_id, v_entity_id, 'PERSONAL-9620', 'Bank Fees & Personal Interest', 'expense',   'financial',    'active', true, false),
    (v_agency_id, v_entity_id, 'PERSONAL-9700', 'Tithe & Charitable',            'expense',   'giving',       'active', true, false),
    (v_agency_id, v_entity_id, 'PERSONAL-9800', 'Discretionary',                 'expense',   'discretionary','active', true, false),
    (v_agency_id, v_entity_id, 'PERSONAL-9900', 'Personal Income Tax',           'expense',   'tax',          'active', true, false),
    (v_agency_id, v_entity_id, 'PERSONAL-9999', 'Personal Suspense',             'expense',   'suspense',     'active', true, true),

    -- EQUITY (2)
    (v_agency_id, v_entity_id, 'PERSONAL-9990', 'Internal Transfers (personal accounts)', 'equity', 'transfer',   'active', true, true),
    (v_agency_id, v_entity_id, 'PERSONAL-9980', 'Owner Draws from PaperNewt',              'equity', 'draw',       'active', true, false),

    -- LIABILITY (3 personal credit cards)
    (v_agency_id, v_entity_id, 'PERSONAL-CC-8847', 'US Bank Personal CC (8847)',       'liability', 'credit_card', 'active', true, false),
    (v_agency_id, v_entity_id, 'PERSONAL-CC-1006', 'AMEX Personal (1006)',             'liability', 'credit_card', 'active', true, false),
    (v_agency_id, v_entity_id, 'PERSONAL-CC-7435', 'Capital One Personal Card (7435)', 'liability', 'credit_card', 'active', true, false)
  ON CONFLICT (agency_id, chart_namespace, account_code) DO NOTHING;

  -- 2. Cache lookups for the loop
  SELECT id INTO v_suspense_coa FROM public.chart_of_accounts
    WHERE agency_id = v_agency_id AND chart_namespace = 'active' AND account_code = 'PERSONAL-9999';
  SELECT id INTO v_transfer_coa FROM public.chart_of_accounts
    WHERE agency_id = v_agency_id AND chart_namespace = 'active' AND account_code = 'PERSONAL-9990';

  -- 3. Link personal credit_accounts.chart_account_id -> new liability COAs
  UPDATE public.credit_accounts ca
     SET chart_account_id = coa.id
    FROM public.chart_of_accounts coa
   WHERE ca.business_entity_id = v_entity_id
     AND ca.agency_id = v_agency_id
     AND ca.chart_account_id IS NULL
     AND coa.agency_id = v_agency_id
     AND coa.chart_namespace = 'active'
     AND coa.account_code = 'PERSONAL-CC-' || ca.account_number_last4;

  -- 4. Backfill JEs for orphan personal bank_txns
  FOR v_txn IN
    SELECT id, transaction_date, description, amount, bank_account_id
      FROM public.bank_transactions
     WHERE business_entity_id = v_entity_id
       AND agency_id = v_agency_id
       AND journal_entry_id IS NULL
     ORDER BY transaction_date, id
  LOOP
    IF v_txn.description ILIKE 'Internet Banking Transfer%' THEN
      v_other_coa := v_transfer_coa;
      v_cls_status := 'classified';
    ELSE
      v_other_coa := v_suspense_coa;
      v_cls_status := 'pending_review';
    END IF;

    v_amt := ABS(v_txn.amount);

    INSERT INTO public.journal_entries
      (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by)
    VALUES
      (v_agency_id, v_entity_id, v_txn.transaction_date, 'personal_bank',
       'PERSONAL BACKFILL: ' || COALESCE(v_txn.description,'(no desc)'),
       'pf4_personal_backfill', v_cls_status, 'phase_4_migration')
    RETURNING id INTO v_je_id;

    IF v_txn.amount >= 0 THEN
      -- Deposit: DR bank asset, CR other side
      INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
      VALUES (v_je_id, v_agency_id, v_txn.bank_account_id, v_amt, 0, v_txn.description, v_entity_id);
      INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
      VALUES (v_je_id, v_agency_id, v_other_coa, 0, v_amt, v_txn.description, v_entity_id);
    ELSE
      -- Withdrawal: CR bank asset, DR other side
      INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
      VALUES (v_je_id, v_agency_id, v_txn.bank_account_id, 0, v_amt, v_txn.description, v_entity_id);
      INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
      VALUES (v_je_id, v_agency_id, v_other_coa, v_amt, 0, v_txn.description, v_entity_id);
    END IF;

    UPDATE public.bank_transactions SET journal_entry_id = v_je_id WHERE id = v_txn.id;
    v_bank_count := v_bank_count + 1;
  END LOOP;

  -- 5. Backfill JEs for orphan personal credit_txns
  FOR v_txn IN
    SELECT ct.id, ct.transaction_date, ct.description, ct.amount,
           ct.credit_account_id, ca.chart_account_id AS coa_id
      FROM public.credit_transactions ct
      JOIN public.credit_accounts ca ON ca.id = ct.credit_account_id
     WHERE ct.business_entity_id = v_entity_id
       AND ct.agency_id = v_agency_id
       AND ct.journal_entry_id IS NULL
     ORDER BY ct.transaction_date, ct.id
  LOOP
    v_amt := ABS(v_txn.amount);

    INSERT INTO public.journal_entries
      (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by)
    VALUES
      (v_agency_id, v_entity_id, v_txn.transaction_date, 'personal_credit',
       'PERSONAL BACKFILL: ' || COALESCE(v_txn.description,'(no desc)'),
       'pf4_personal_backfill', 'pending_review', 'phase_4_migration')
    RETURNING id INTO v_je_id;

    IF v_txn.amount >= 0 THEN
      -- Charge: CR credit liability (liability up), DR suspense (expense-like)
      INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
      VALUES (v_je_id, v_agency_id, v_txn.coa_id, 0, v_amt, v_txn.description, v_entity_id);
      INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
      VALUES (v_je_id, v_agency_id, v_suspense_coa, v_amt, 0, v_txn.description, v_entity_id);
    ELSE
      -- Payment / refund: DR credit liability (liability down), CR suspense
      INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
      VALUES (v_je_id, v_agency_id, v_txn.coa_id, v_amt, 0, v_txn.description, v_entity_id);
      INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
      VALUES (v_je_id, v_agency_id, v_suspense_coa, 0, v_amt, v_txn.description, v_entity_id);
    END IF;

    UPDATE public.credit_transactions SET journal_entry_id = v_je_id WHERE id = v_txn.id;
    v_credit_count := v_credit_count + 1;
  END LOOP;

  RAISE NOTICE 'pf4 backfill complete: % bank JEs, % credit JEs posted', v_bank_count, v_credit_count;
END
$migration$;
