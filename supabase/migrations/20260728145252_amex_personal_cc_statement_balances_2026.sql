-- AMEX Personal Cash Magnet (COA-PERSONAL-CC-1006) — 2026 statement balances ingest
-- Note the sign: credit balances stored as NEGATIVE closing_balance so account rolls up correctly.

DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_entity uuid;
BEGIN
  SELECT id INTO v_entity FROM public.business_entities
  WHERE agency_id = v_agency AND name = 'Peter Story';

  -- Remove stale null-period estimate row
  DELETE FROM public.statement_balances
  WHERE agency_id = v_agency
    AND account_last4 = '1006'
    AND statement_period_start IS NULL;

  -- Insert per-cycle balances (26-03 through 26-07). Card was inactive in Jan/Feb.
  -- Credit balances (AMEX owes Peter) are stored as NEGATIVE closing_balance
  INSERT INTO public.statement_balances
    (agency_id, business_entity_id, account_code, account_last4, account_kind,
     statement_period_start, statement_period_end, opening_balance, closing_balance,
     source, notes)
  VALUES
    (v_agency, v_entity, 'COA-PERSONAL-CC-1006', '1006', 'credit',
     '2026-02-19', '2026-03-18', 0.00, -493.01,
     'statement_pdf_ingest', 'AMEX Personal CC 26-03 (credit adj -$493.01)'),
    (v_agency, v_entity, 'COA-PERSONAL-CC-1006', '1006', 'credit',
     '2026-03-19', '2026-04-17', -493.01, -493.01,
     'statement_pdf_ingest', 'AMEX Personal CC 26-04 (no activity)'),
    (v_agency, v_entity, 'COA-PERSONAL-CC-1006', '1006', 'credit',
     '2026-04-18', '2026-05-18', -493.01, -493.01,
     'statement_pdf_ingest', 'AMEX Personal CC 26-05 (no activity)'),
    (v_agency, v_entity, 'COA-PERSONAL-CC-1006', '1006', 'credit',
     '2026-05-19', '2026-06-17', -493.01, -493.01,
     'statement_pdf_ingest', 'AMEX Personal CC 26-06 (no activity)'),
    (v_agency, v_entity, 'COA-PERSONAL-CC-1006', '1006', 'credit',
     '2026-06-18', '2026-07-17', -493.01, 0.00,
     'statement_pdf_ingest', 'AMEX Personal CC 26-07 (credit bal refund +$493.01)');
END $$;
