-- AMEX Discretionary Blue Business Cash (ending 1003, COA-009) — 2026 statement balances ingest
-- 7 cycles all reconcile penny-perfect on both payments/credits AND new charges against
-- parsed statements (26-01 through 26-07). Card is on Peter Story State Farm agency (b2222222).
-- Also updates credit_accounts.current_balance ($7,143.51 stale → $5,460.25 from 26-07 close),
-- last4 (NULL → 1003), statement_close_day (NULL → 15).

DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_entity uuid := 'b2222222-2222-2222-2222-222222222222';  -- Peter Story State Farm
BEGIN
  -- Remove stale ledger_snapshot row
  DELETE FROM public.statement_balances
  WHERE agency_id = v_agency
    AND account_code = 'COA-009'
    AND source = 'ledger_snapshot_20260630';

  -- Insert 7 real statement_balances rows
  INSERT INTO public.statement_balances
    (agency_id, business_entity_id, account_code, account_last4, account_kind,
     statement_period_start, statement_period_end, opening_balance, closing_balance,
     source, notes)
  VALUES
    (v_agency, v_entity, 'COA-009', '1003', 'credit',
     '2025-12-16', '2026-01-15', 4659.57, 4874.59,
     'statement_pdf_ingest', 'AMEX Discretionary 26-01 | prev 4659.57 - pmt/cr 4753.96 + charges 4968.98 = 4874.59 | 64 tx'),
    (v_agency, v_entity, 'COA-009', '1003', 'credit',
     '2026-01-16', '2026-02-12', 4874.59, 3686.21,
     'statement_pdf_ingest', 'AMEX Discretionary 26-02 | prev 4874.59 - pmt/cr 5051.45 + charges 3863.07 = 3686.21 | 65 tx'),
    (v_agency, v_entity, 'COA-009', '1003', 'credit',
     '2026-02-13', '2026-03-15', 3686.21, 3458.12,
     'statement_pdf_ingest', 'AMEX Discretionary 26-03 | prev 3686.21 - pmt/cr 3760.74 + charges 3532.65 = 3458.12 | 59 tx'),
    (v_agency, v_entity, 'COA-009', '1003', 'credit',
     '2026-03-16', '2026-04-14', 3458.12, 6076.48,
     'statement_pdf_ingest', 'AMEX Discretionary 26-04 | prev 3458.12 - pmt/cr 3527.61 + charges 6145.97 = 6076.48 | 105 tx'),
    (v_agency, v_entity, 'COA-009', '1003', 'credit',
     '2026-04-15', '2026-05-15', 6076.48, 3255.07,
     'statement_pdf_ingest', 'AMEX Discretionary 26-05 | prev 6076.48 - pmt/cr 6198.23 + charges 3376.82 = 3255.07 | 72 tx'),
    (v_agency, v_entity, 'COA-009', '1003', 'credit',
     '2026-05-16', '2026-06-14', 3255.07, 2999.91,
     'statement_pdf_ingest', 'AMEX Discretionary 26-06 | prev 3255.07 - pmt/cr 3382.91 + charges 3127.75 = 2999.91 | 47 tx'),
    (v_agency, v_entity, 'COA-009', '1003', 'credit',
     '2026-06-15', '2026-07-15', 2999.91, 5460.25,
     'statement_pdf_ingest', 'AMEX Discretionary 26-07 | prev 2999.91 - pmt/cr 3061.25 + charges 5521.59 = 5460.25 | 51 tx')
  ON CONFLICT (agency_id, account_code, statement_period_end) DO NOTHING;

  -- Update credit_accounts row
  UPDATE public.credit_accounts
  SET account_number_last4 = '1003',
      current_balance      = 5460.25,
      statement_close_day  = 15,
      updated_at           = NOW()
  WHERE id = '3dacdd99-49b1-49f7-8bcf-50fcc0e992c0';
END $$;
