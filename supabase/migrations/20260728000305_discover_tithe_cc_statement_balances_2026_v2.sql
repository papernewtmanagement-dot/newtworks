-- Discover Tithe CC (COA-PERSONAL-CC-3208) — 2026 statement balances ingest
-- account_kind constraint is ('bank','credit'), not 'credit_card' — fixed here.

DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_entity uuid;
BEGIN
  SELECT id INTO v_entity FROM public.business_entities
  WHERE agency_id = v_agency AND name = 'Peter Story';

  -- Remove the stale single-row estimate
  DELETE FROM public.statement_balances
  WHERE agency_id = v_agency
    AND account_last4 = '3208'
    AND statement_period_start IS NULL
    AND statement_period_end = '2026-06-30';

  INSERT INTO public.statement_balances
    (agency_id, business_entity_id, account_code, account_last4, account_kind,
     statement_period_start, statement_period_end, opening_balance, closing_balance,
     source, notes)
  VALUES
    (v_agency, v_entity, 'COA-PERSONAL-CC-3208', '3208', 'credit',
     '2025-12-28', '2026-01-27', 4688.82, 3566.38,
     'statement_pdf_ingest', 'Discover Tithe CC 26-01'),
    (v_agency, v_entity, 'COA-PERSONAL-CC-3208', '3208', 'credit',
     '2026-01-28', '2026-02-27', 3566.38, 3566.38,
     'statement_pdf_ingest', 'Discover Tithe CC 26-02'),
    (v_agency, v_entity, 'COA-PERSONAL-CC-3208', '3208', 'credit',
     '2026-02-28', '2026-03-27', 3566.38, 3566.38,
     'statement_pdf_ingest', 'Discover Tithe CC 26-03'),
    (v_agency, v_entity, 'COA-PERSONAL-CC-3208', '3208', 'credit',
     '2026-04-28', '2026-05-27', 5571.79, 3566.38,
     'statement_pdf_ingest', 'Discover Tithe CC 26-05'),
    (v_agency, v_entity, 'COA-PERSONAL-CC-3208', '3208', 'credit',
     '2026-05-28', '2026-06-27', 3566.38, 5132.76,
     'statement_pdf_ingest', 'Discover Tithe CC 26-06');
END $$;
