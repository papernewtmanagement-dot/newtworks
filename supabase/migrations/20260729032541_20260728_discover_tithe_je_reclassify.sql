-- ============================================================================
-- Discover Tithe CC 3208 — rebuild broken JEs + delete double-count plugs
-- ============================================================================
-- Discover Tithe CC 3208 is a dedicated-purpose card: every charge = Tithe & Charitable.
-- Some transactions were classified correctly via pf4j_discover_ingest; the rest sat in
-- Suspense with pending_review status via cc_gl_writer.
--
-- Also delete two plug JEs that were placeholders for now-classifiable individual charges:
--   - pf4n_discover_opening: Jan 2026 opening plug $3,566.38
--   - pf4m_discover_inferred: May 2026 aggregate $3,566.38 (covering Apr 27-29 charges
--     which we're now posting individually)
--
-- Keep pf4o_tithe_reconcile plugs: those cover in-kind Venmo + not-yet-ingested June
-- individual charges (no underlying credit_transactions to replace them).
-- ============================================================================

DO $rebuild$
DECLARE
  v_agency_id   uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_entity_id   uuid := 'b3333333-3333-3333-3333-333333333333';
  v_agency_ent  uuid := 'b2222222-2222-2222-2222-222222222222';
  v_tithe_acct  uuid;
  v_transfer_acct uuid;
  v_cc_3208_acct uuid;
  r record;
  v_dr_amt numeric;
  v_cr_amt numeric;
  n_rebuilt int := 0;
  n_plugs_deleted int := 0;
BEGIN
  -- Look up account IDs
  SELECT id INTO v_tithe_acct    FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND account_code='COA-PERSONAL-9700';
  SELECT id INTO v_transfer_acct FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND account_code='COA-PERSONAL-9990';
  SELECT id INTO v_cc_3208_acct  FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND account_code='COA-PERSONAL-CC-3208';

  IF v_tithe_acct IS NULL OR v_transfer_acct IS NULL OR v_cc_3208_acct IS NULL THEN
    RAISE EXCEPTION 'Missing required COA: tithe=% transfer=% cc3208=%', v_tithe_acct, v_transfer_acct, v_cc_3208_acct;
  END IF;

  -- Step 1: Rebuild broken Discover 3208 JEs (any pending_review OR hitting Suspense OR wrong entity)
  FOR r IN
    SELECT DISTINCT
      ct.id AS ct_id,
      ct.transaction_date,
      ct.amount,
      ct.description,
      ct.journal_entry_id AS je_id
    FROM public.credit_transactions ct
    JOIN public.credit_accounts ca ON ca.id = ct.credit_account_id
    WHERE ca.account_number_last4 = '3208'
      AND ct.journal_entry_id IS NOT NULL
      AND ct.transaction_date >= '2026-01-01'
      AND EXISTS (
        SELECT 1 FROM public.journal_lines jl
        LEFT JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
        WHERE jl.journal_entry_id = ct.journal_entry_id
          AND (
            coa.account_code IN ('COA-SUSP','COA-018')
            OR jl.business_entity_id = v_agency_ent
          )
      )
  LOOP
    IF r.amount >= 0 THEN
      -- Charge: DR Tithe & Charitable / CR CC-3208 liability
      v_dr_amt := r.amount;
      v_cr_amt := r.amount;
      DELETE FROM public.journal_lines WHERE journal_entry_id = r.je_id;
      INSERT INTO public.journal_lines
        (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
      VALUES
        (r.je_id, v_agency_id, v_tithe_acct,   v_dr_amt, 0,        r.description, v_entity_id),
        (r.je_id, v_agency_id, v_cc_3208_acct, 0,        v_cr_amt, r.description, v_entity_id);
    ELSE
      -- Payment: DR CC-3208 (reduce liability) / CR Internal Transfers (personal accounts)
      v_dr_amt := ABS(r.amount);
      v_cr_amt := ABS(r.amount);
      DELETE FROM public.journal_lines WHERE journal_entry_id = r.je_id;
      INSERT INTO public.journal_lines
        (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
      VALUES
        (r.je_id, v_agency_id, v_cc_3208_acct,   v_dr_amt, 0,        r.description, v_entity_id),
        (r.je_id, v_agency_id, v_transfer_acct,  0,        v_cr_amt, r.description, v_entity_id);
    END IF;

    UPDATE public.journal_entries
    SET business_entity_id  = v_entity_id,
        classification_status = 'classified',
        suspense_reason       = NULL,
        source                = 'pf4j_discover_ingest',
        classified_by         = 'claude-2026-07-28-discover-tithe-fix',
        classified_at         = NOW()
    WHERE id = r.je_id;

    n_rebuilt := n_rebuilt + 1;
  END LOOP;

  RAISE NOTICE 'Rebuilt % broken Discover 3208 JEs', n_rebuilt;

  -- Step 2: Delete the double-count plugs
  -- 2a. Jan opening plug (aggregate January tithe)
  WITH jan_plug AS (
    SELECT je.id FROM public.journal_entries je
    WHERE je.source = 'pf4n_discover_opening'
      AND je.agency_id = v_agency_id
  ), del_lines AS (
    DELETE FROM public.journal_lines WHERE journal_entry_id IN (SELECT id FROM jan_plug) RETURNING 1
  )
  DELETE FROM public.journal_entries WHERE id IN (SELECT id FROM jan_plug);

  GET DIAGNOSTICS n_plugs_deleted = ROW_COUNT;
  RAISE NOTICE 'Deleted % Jan opening plug JEs (pf4n_discover_opening)', n_plugs_deleted;

  -- 2b. May inferred aggregate plug
  WITH may_plug AS (
    SELECT je.id FROM public.journal_entries je
    WHERE je.source = 'pf4m_discover_inferred'
      AND je.agency_id = v_agency_id
  ), del_lines AS (
    DELETE FROM public.journal_lines WHERE journal_entry_id IN (SELECT id FROM may_plug) RETURNING 1
  )
  DELETE FROM public.journal_entries WHERE id IN (SELECT id FROM may_plug);

  GET DIAGNOSTICS n_plugs_deleted = ROW_COUNT;
  RAISE NOTICE 'Deleted % May inferred plug JEs (pf4m_discover_inferred)', n_plugs_deleted;

END $rebuild$;
