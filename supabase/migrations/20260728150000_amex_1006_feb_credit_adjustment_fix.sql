-- ============================================================================
-- AMEX 1006 Feb 2026 Credit Adjustment JEs — same-class bug-fix sweep
-- ============================================================================
-- 2 broken JEs on Feb 26 for CREDIT ADJUSTMENT -$493.01 each (AMEX rewards).
-- Current shape: DR COA-SUSP on agency entity / CR CC-1006 on personal entity (nonsensical).
-- Correct shape for a CC credit adjustment: DR CC-liability (reduce liability) /
-- CR Credit Card Rewards contra-expense (reduces total P&L expenses).
-- ============================================================================

DO $rebuild$
DECLARE
  v_agency_id  uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_entity_id  uuid := 'b3333333-3333-3333-3333-333333333333';
  v_cc_1006    uuid;
  v_rewards    uuid;
  r record;
  n_rebuilt int := 0;
BEGIN
  SELECT id INTO v_cc_1006 FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND account_code='COA-PERSONAL-CC-1006';
  SELECT id INTO v_rewards FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND account_code='COA-PERSONAL-9820';

  IF v_cc_1006 IS NULL OR v_rewards IS NULL THEN
    RAISE EXCEPTION 'Missing COA: cc_1006=% rewards=%', v_cc_1006, v_rewards;
  END IF;

  FOR r IN
    SELECT ct.id AS ct_id, ct.transaction_date, ct.amount, ct.description, ct.journal_entry_id AS je_id
    FROM public.credit_transactions ct
    JOIN public.credit_accounts ca ON ca.id = ct.credit_account_id
    WHERE ca.account_number_last4 = '1006'
      AND ct.transaction_date >= '2026-02-01' AND ct.transaction_date <= '2026-02-28'
      AND ct.amount < 0
      AND ct.journal_entry_id IS NOT NULL
  LOOP
    DELETE FROM public.journal_lines WHERE journal_entry_id = r.je_id;
    INSERT INTO public.journal_lines
      (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
    VALUES
      (r.je_id, v_agency_id, v_cc_1006, ABS(r.amount), 0,             r.description, v_entity_id),
      (r.je_id, v_agency_id, v_rewards, 0,             ABS(r.amount), r.description, v_entity_id);

    UPDATE public.journal_entries
    SET business_entity_id  = v_entity_id,
        classification_status = 'classified',
        suspense_reason       = NULL,
        classified_by         = 'claude-2026-07-28-amex-feb-fix',
        classified_at         = NOW()
    WHERE id = r.je_id;

    n_rebuilt := n_rebuilt + 1;
  END LOOP;

  RAISE NOTICE 'Rebuilt % AMEX 1006 Feb credit adjustment JEs', n_rebuilt;
END $rebuild$;
