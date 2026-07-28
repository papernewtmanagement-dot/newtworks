-- Chase Marketing 1 (7762/7770 merged) statement ingest — 6 cycles Dec 2025–Jun 2026
-- Adds 70 new credit_transactions + matching JEs (cc_gl_writer pending_review pattern)
-- + 6 statement_balances. Skips 12 dedup'd rows already ingested from 26-06 statement.

-- 1. Insert 6 statement_balances
INSERT INTO public.statement_balances (
  agency_id, business_entity_id, account_code, account_last4, account_kind,
  statement_period_start, statement_period_end, opening_balance, closing_balance,
  source, notes
) VALUES
  ('126794dd-25ff-47d2-a436-724499733365','b2222222-2222-2222-2222-222222222222','COA-011','7762','credit','2025-12-23','2026-01-22',2478.95,2499.48,'statement_pdf_ingest','Chase Marketing 26-01 | prev 2478.95 - pmt/cr 2478.95 + charges 2499.48 = 2499.48 | 10 tx'),
  ('126794dd-25ff-47d2-a436-724499733365','b2222222-2222-2222-2222-222222222222','COA-011','7762','credit','2026-01-23','2026-02-22',2499.48,2745.93,'statement_pdf_ingest','Chase Marketing 26-02 | prev 2499.48 - pmt/cr 2499.48 + charges 2745.93 = 2745.93 | 11 tx'),
  ('126794dd-25ff-47d2-a436-724499733365','b2222222-2222-2222-2222-222222222222','COA-011','7762','credit','2026-02-23','2026-03-22',2745.93,3162.56,'statement_pdf_ingest','Chase Marketing 26-03 | prev 2745.93 - pmt/cr 2745.93 + charges 3162.56 = 3162.56 | 13 tx'),
  ('126794dd-25ff-47d2-a436-724499733365','b2222222-2222-2222-2222-222222222222','COA-011','7762','credit','2026-03-23','2026-04-22',3162.56,4844.24,'statement_pdf_ingest','Chase Marketing 26-04 | prev 3162.56 - pmt/cr 3162.56 + charges 4844.24 = 4844.24 | 18 tx'),
  ('126794dd-25ff-47d2-a436-724499733365','b2222222-2222-2222-2222-222222222222','COA-011','7762','credit','2026-04-23','2026-05-22',4844.24,4986.04,'statement_pdf_ingest','Chase Marketing 26-05 | prev 4844.24 - pmt/cr 4844.24 + charges 4986.04 = 4986.04 | 18 tx'),
  ('126794dd-25ff-47d2-a436-724499733365','b2222222-2222-2222-2222-222222222222','COA-011','7762','credit','2026-05-23','2026-06-22',4986.04,3923.55,'statement_pdf_ingest','Chase Marketing 26-06 | prev 4986.04 - pmt/cr 4986.04 + charges 3923.55 = 3923.55 | 12 tx');

-- 2. Insert 70 credit_transactions + matching JEs + JLs via DO block
DO $ingest$
DECLARE
  rec record;
  je_id uuid;
  agency_id_v uuid := '126794dd-25ff-47d2-a436-724499733365';
  cc_id_v uuid := '37c0a92a-66b8-42d4-a602-cd36734f375f';
  entity_id_v uuid := 'b2222222-2222-2222-2222-222222222222';
  cc_account_id uuid;
  susp_account_id uuid;
  cc_name_v text := 'Chase - Marketing 1';
  n_charge int := 0;
  n_payment int := 0;
BEGIN
  SELECT id INTO cc_account_id FROM public.chart_of_accounts
    WHERE account_code='COA-011' AND agency_id = agency_id_v;
  SELECT id INTO susp_account_id FROM public.chart_of_accounts
    WHERE account_code='COA-SUSP' AND agency_id = agency_id_v;

  IF cc_account_id IS NULL OR susp_account_id IS NULL THEN
    RAISE EXCEPTION 'Missing COA-011 or COA-SUSP account';
  END IF;

  FOR rec IN
    SELECT * FROM jsonb_to_recordset('[{"d": "2026-01-14", "desc_": "Payment Thank You - Web", "amt": "-2478.95", "ttype": "payment"}, {"d": "2025-12-22", "desc_": "QUOTEWIZARD 877-9166344 WA", "amt": "250.00", "ttype": "charge"}, {"d": "2025-12-29", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2025-12-30", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-01-05", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-01-06", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-01-15", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-01-16", "desc_": "INSURANCEQUOTES 877-8289792 TX", "amt": "249.93", "ttype": "charge"}, {"d": "2026-01-17", "desc_": "AGENT TAGGED MEDIA AGENTHOODPROG NY", "amt": "499.55", "ttype": "charge"}, {"d": "2026-01-21", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-02-13", "desc_": "Payment Thank You - Web", "amt": "-2499.48", "ttype": "payment"}, {"d": "2026-01-27", "desc_": "QUOTEWIZARD 877-9166344 WA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-01-28", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-02-01", "desc_": "INSURANCEQUOTES 877-8289792 TX", "amt": "187.45", "ttype": "charge"}, {"d": "2026-02-02", "desc_": "AGENT TAG* AGENT TAGGE 184-47362844 NY", "amt": "309.00", "ttype": "charge"}, {"d": "2026-02-10", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-02-13", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-02-16", "desc_": "INSURANCEQUOTES 877-8289792 TX", "amt": "249.93", "ttype": "charge"}, {"d": "2026-02-17", "desc_": "AGENT TAGGED MEDIA AGENTHOODPROG NY", "amt": "499.55", "ttype": "charge"}, {"d": "2026-02-17", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-02-20", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-03-13", "desc_": "Payment Thank You - Web", "amt": "-2703.80", "ttype": "payment"}, {"d": "2026-03-05", "desc_": "BUTLER/TILL ROCHESTER NY", "amt": "-42.13", "ttype": "payment"}, {"d": "2026-02-23", "desc_": "QUOTEWIZARD 877-9166344 WA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-02-25", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-02-27", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-03-02", "desc_": "AGENT TAG* AGENT TAGGE 184-47362844 NY", "amt": "309.00", "ttype": "charge"}, {"d": "2026-03-01", "desc_": "INSURANCEQUOTES 877-8289792 TX", "amt": "312.42", "ttype": "charge"}, {"d": "2026-03-02", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-03-16", "desc_": "INSURANCEQUOTES 877-8289792 TX", "amt": "291.59", "ttype": "charge"}, {"d": "2026-03-17", "desc_": "BUTLER/TILL AGENTHOODPROG NY", "amt": "499.55", "ttype": "charge"}, {"d": "2026-03-19", "desc_": "QUOTEWIZARD 877-9166344 WA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-03-19", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-03-21", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-04-15", "desc_": "Payment Thank You - Web", "amt": "-3162.56", "ttype": "payment"}, {"d": "2026-03-24", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-03-26", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-03-27", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-04-01", "desc_": "AGENT TAG* AGENT TAGGE 184-47362844 NY", "amt": "309.00", "ttype": "charge"}, {"d": "2026-03-31", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-04-01", "desc_": "INSURANCEQUOTES 877-8289792 TX", "amt": "333.24", "ttype": "charge"}, {"d": "2026-04-03", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-04-08", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-04-13", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-04-15", "desc_": "QUOTEWIZARD 877-9166344 WA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-04-16", "desc_": "INSURANCEQUOTES 877-8289792 TX", "amt": "187.45", "ttype": "charge"}, {"d": "2026-04-16", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-04-17", "desc_": "BUTLER/TILL AGENTHOODPROG NY", "amt": "499.55", "ttype": "charge"}, {"d": "2026-04-17", "desc_": "BUTLER/TILL 184-47362844 NY", "amt": "515.00", "ttype": "charge"}, {"d": "2026-04-20", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-04-21", "desc_": "QUOTEWIZARD 877-9166344 WA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-04-21", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-05-13", "desc_": "Payment Thank You - Web", "amt": "-4844.24", "ttype": "payment"}, {"d": "2026-04-23", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-04-28", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-05-01", "desc_": "AGENT TAG* AGENT TAGGE 184-47362844 NY", "amt": "309.00", "ttype": "charge"}, {"d": "2026-05-01", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "600.00", "ttype": "charge"}, {"d": "2026-05-01", "desc_": "INSURANCEQUOTES 877-8289792 TX", "amt": "20.83", "ttype": "charge"}, {"d": "2026-05-04", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-05-05", "desc_": "QUOTEWIZARD 877-9166344 WA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-05-10", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-05-10", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-05-11", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-05-12", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-05-14", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-05-17", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-05-16", "desc_": "INSURANCEQUOTES 877-8289792 TX", "amt": "41.66", "ttype": "charge"}, {"d": "2026-05-17", "desc_": "BUTLER/TILL AGENTHOODPROG NY", "amt": "1014.55", "ttype": "charge"}, {"d": "2026-05-19", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}, {"d": "2026-05-21", "desc_": "EVERQUOTE, INC PRO.EVERQUOTE MA", "amt": "250.00", "ttype": "charge"}]'::jsonb)
      AS x(d date, desc_ text, amt numeric, ttype text)
  LOOP
    INSERT INTO public.journal_entries (
      agency_id, entry_date, description, source,
      classification_status, suspense_reason, business_entity_id
    ) VALUES (
      agency_id_v, rec.d, rec.desc_ || ' [' || cc_name_v || ']', 'cc_gl_writer',
      'pending_review', 'no_category_provided', entity_id_v
    ) RETURNING id INTO je_id;

    IF rec.amt > 0 THEN
      -- Charge: Dr CC, Cr SUSP (matches existing pattern across all cards)
      INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
      VALUES
        (je_id, agency_id_v, cc_account_id,   rec.amt, 0, entity_id_v),
        (je_id, agency_id_v, susp_account_id, 0, rec.amt, entity_id_v);
      n_charge := n_charge + 1;
    ELSE
      -- Payment: Dr SUSP, Cr CC (mirror)
      INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
      VALUES
        (je_id, agency_id_v, susp_account_id, -rec.amt, 0, entity_id_v),
        (je_id, agency_id_v, cc_account_id,   0, -rec.amt, entity_id_v);
      n_payment := n_payment + 1;
    END IF;

    INSERT INTO public.credit_transactions (
      agency_id, credit_account_id, transaction_date, description,
      amount, transaction_type, journal_entry_id, business_entity_id
    ) VALUES (
      agency_id_v, cc_id_v, rec.d, rec.desc_,
      rec.amt, rec.ttype, je_id, entity_id_v
    );
  END LOOP;

  RAISE NOTICE 'Chase ingest: charges=%, payments=%', n_charge, n_payment;
END$ingest$;
