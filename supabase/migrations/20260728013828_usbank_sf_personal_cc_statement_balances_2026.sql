-- US Bank SF Personal CC (COA-PERSONAL-CC-8847) — 2026 statement balances ingest
-- All 7 cycles reconcile against existing 29 credit_transactions rows.
-- Card is State Farm Premier Cash Rewards Visa Signature ending 8847 (Peter Story personal).

DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_entity uuid;
BEGIN
  SELECT id INTO v_entity FROM public.business_entities
  WHERE agency_id = v_agency AND name = 'Peter Story';

  -- Remove the pre-existing single-row estimate (correct closing amount but null period)
  DELETE FROM public.statement_balances
  WHERE agency_id = v_agency
    AND account_last4 = '8847'
    AND statement_period_start IS NULL;

  INSERT INTO public.statement_balances
    (agency_id, business_entity_id, account_code, account_last4, account_kind,
     statement_period_start, statement_period_end, opening_balance, closing_balance,
     source, notes)
  VALUES
    (v_agency, v_entity, 'COA-PERSONAL-CC-8847', '8847', 'credit',
     '2025-12-09', '2026-01-08', 639.71, 536.50,
     'statement_pdf_ingest', 'US Bank SF Personal CC 26-01'),
    (v_agency, v_entity, 'COA-PERSONAL-CC-8847', '8847', 'credit',
     '2026-01-09', '2026-02-06', 536.50, 536.48,
     'statement_pdf_ingest', 'US Bank SF Personal CC 26-02'),
    (v_agency, v_entity, 'COA-PERSONAL-CC-8847', '8847', 'credit',
     '2026-02-07', '2026-03-06', 536.48, 536.48,
     'statement_pdf_ingest', 'US Bank SF Personal CC 26-03'),
    (v_agency, v_entity, 'COA-PERSONAL-CC-8847', '8847', 'credit',
     '2026-03-07', '2026-04-07', 536.48, 536.48,
     'statement_pdf_ingest', 'US Bank SF Personal CC 26-04'),
    (v_agency, v_entity, 'COA-PERSONAL-CC-8847', '8847', 'credit',
     '2026-04-08', '2026-05-07', 536.48, 546.15,
     'statement_pdf_ingest', 'US Bank SF Personal CC 26-05'),
    (v_agency, v_entity, 'COA-PERSONAL-CC-8847', '8847', 'credit',
     '2026-05-08', '2026-06-05', 546.15, 984.41,
     'statement_pdf_ingest', 'US Bank SF Personal CC 26-06'),
    (v_agency, v_entity, 'COA-PERSONAL-CC-8847', '8847', 'credit',
     '2026-06-06', '2026-07-08', 984.41, 113.00,
     'statement_pdf_ingest', 'US Bank SF Personal CC 26-07');
END $$;
