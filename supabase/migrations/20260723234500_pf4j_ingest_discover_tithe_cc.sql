-- =====================================================================
-- Phase 4j: Ingest Discover Tithe CC (3208)
-- 1. Create Discover credit_account + COA-PERSONAL-CC-3208 liability + link
-- 2. Insert 18 credit_transactions from statements (Feb-Mar, Mar-Apr, May-Jun)
-- 3. Post JEs:
--    Charges (all tithe/charitable per Peter, incl. Amazon on Discover = Vault donations):
--      DR Tithe & Charitable, CR Discover CC
--    Payments received (INTERNET PAYMENT - THANK YOU):
--      DR Discover CC, CR Internal Transfers (mirrors bank withdrawal)
-- 4. Reclassify existing 3 bank Discover withdrawals from *Unclassified to Internal Transfers
-- 5. Seed classification rules
-- =====================================================================
-- NOTE: Statement 04/28-05/27 not uploaded. Bank shows a $5,571.79 payment on
-- 5/8 that would map to that missing statement's payoff. Internal Transfers
-- carries $5,571.79 dangling on debit side until that statement is ingested.
-- Similarly, the 3/18 Discover payment is before the ingested bank window,
-- leaving $3,566.38 dangling on credit side.
-- Net dangling: $2,005.41 (= Amazon Vault donation charge).
-- =====================================================================

DO $pf4j$
DECLARE
  v_agency_id      UUID := '126794dd-25ff-47d2-a436-724499733365';
  v_pers_id        UUID := 'b3333333-3333-3333-3333-333333333333';
  v_discover_ca_id UUID;
  v_discover_coa_id UUID;
  v_tithe_coa_id   UUID;
  v_transfers_coa_id UUID;
  v_susp_out_id    UUID;
  v_txn RECORD;
  v_je_id UUID;
  v_amt NUMERIC;
BEGIN

  INSERT INTO public.chart_of_accounts
    (agency_id, business_entity_id, account_code, account_name, account_type, account_subtype, chart_namespace, is_active, is_system)
  VALUES
    (v_agency_id, v_pers_id, 'COA-PERSONAL-CC-3208', 'Discover Tithe CC (3208)',
     'liability', 'credit_card', 'active', true, false)
  ON CONFLICT (agency_id, chart_namespace, account_code) DO NOTHING;

  SELECT id INTO v_discover_coa_id FROM public.chart_of_accounts
    WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-CC-3208';

  INSERT INTO public.credit_accounts
    (agency_id, business_entity_id, account_name, institution, account_number_last4,
     account_type, credit_limit, chart_account_id, is_active)
  VALUES
    (v_agency_id, v_pers_id, 'Discover Tithe CC', 'Discover', '3208',
     'credit_card', 36500.00, v_discover_coa_id, true)
  RETURNING id INTO v_discover_ca_id;

  SELECT id INTO v_tithe_coa_id       FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-9700';
  SELECT id INTO v_transfers_coa_id   FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-9990';
  SELECT id INTO v_susp_out_id        FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-9999';

  INSERT INTO public.credit_transactions
    (agency_id, business_entity_id, credit_account_id, transaction_date, description, amount, transaction_type)
  VALUES
    (v_agency_id, v_pers_id, v_discover_ca_id, '2026-02-27', 'REASONABLE FAITH 4349442618 TX',              1000.00,  'charge'),
    (v_agency_id, v_pers_id, v_discover_ca_id, '2026-02-28', 'NPO* VAULT FOSTERING C 6159530083 TX',         566.38,  'charge'),
    (v_agency_id, v_pers_id, v_discover_ca_id, '2026-03-02', 'GIV*CHRIST COMMUNITY CHU 210-318-3353 TX',    1000.00,  'charge'),
    (v_agency_id, v_pers_id, v_discover_ca_id, '2026-03-02', 'PAYPAL *ACTMIN 888-221-1161 CA',              1000.00,  'charge'),
    (v_agency_id, v_pers_id, v_discover_ca_id, '2026-03-18', 'INTERNET PAYMENT - THANK YOU',              -3566.38,  'payment'),
    (v_agency_id, v_pers_id, v_discover_ca_id, '2026-03-29', 'NPO* VAULT FOSTERING C 6159530083 TX',         566.38,  'charge'),
    (v_agency_id, v_pers_id, v_discover_ca_id, '2026-03-29', 'REASONABLE FAITH 4349442618 TX',              1000.00,  'charge'),
    (v_agency_id, v_pers_id, v_discover_ca_id, '2026-04-01', 'GIV*CHRIST COMMUNITY CHU 210-318-3353 TX',    1000.00,  'charge'),
    (v_agency_id, v_pers_id, v_discover_ca_id, '2026-04-02', 'PAYPAL *ACTMIN 888-221-1161 CA',              1000.00,  'charge'),
    (v_agency_id, v_pers_id, v_discover_ca_id, '2026-04-04', 'INTERNET PAYMENT - THANK YOU',              -3566.38,  'payment'),
    (v_agency_id, v_pers_id, v_discover_ca_id, '2026-04-09', 'AMAZON MKTPL*BY2AT2NM2 AMZN.COM/BILLWA',      2005.41,  'charge'),
    (v_agency_id, v_pers_id, v_discover_ca_id, '2026-05-28', 'GIV*CHRIST COMMUNITY CHU 210-318-3353 TX',    1000.00,  'charge'),
    (v_agency_id, v_pers_id, v_discover_ca_id, '2026-05-28', 'PAYPAL *ACTMIN 888-221-1161 CA',              1000.00,  'charge'),
    (v_agency_id, v_pers_id, v_discover_ca_id, '2026-05-29', 'NPO* VAULT FOSTERING C 6159530083 TX',         566.38,  'charge'),
    (v_agency_id, v_pers_id, v_discover_ca_id, '2026-05-29', 'REASONABLE FAITH 4349442618 TX',              1000.00,  'charge'),
    (v_agency_id, v_pers_id, v_discover_ca_id, '2026-06-11', 'INTERNET PAYMENT - THANK YOU',              -3566.38,  'payment'),
    (v_agency_id, v_pers_id, v_discover_ca_id, '2026-06-18', 'REASONABLE FAITH 4349442618 TX',              1000.00,  'charge'),
    (v_agency_id, v_pers_id, v_discover_ca_id, '2026-06-19', 'NPO* VAULT FOSTERING C 6159530083 TX',         566.38,  'charge');

  FOR v_txn IN
    SELECT ct.id, ct.transaction_date, ct.description, ct.amount
    FROM public.credit_transactions ct
    WHERE ct.credit_account_id = v_discover_ca_id
      AND ct.journal_entry_id IS NULL
    ORDER BY ct.transaction_date, ct.id
  LOOP
    v_amt := ABS(v_txn.amount);
    IF v_txn.amount < 0 THEN
      INSERT INTO public.journal_entries
        (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
      VALUES
        (v_agency_id, v_pers_id, v_txn.transaction_date, 'personal_credit',
         'DISCOVER: ' || v_txn.description,
         'pf4j_discover_ingest', 'classified', 'phase_4j_migration',
         'Payment received on Discover Tithe CC; mirrors bank withdrawal')
      RETURNING id INTO v_je_id;
      INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
      VALUES (v_je_id, v_agency_id, v_discover_coa_id,    v_amt, 0, v_txn.description, v_pers_id);
      INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
      VALUES (v_je_id, v_agency_id, v_transfers_coa_id,   0, v_amt, v_txn.description, v_pers_id);
    ELSE
      INSERT INTO public.journal_entries
        (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
      VALUES
        (v_agency_id, v_pers_id, v_txn.transaction_date, 'personal_credit',
         'DISCOVER: ' || v_txn.description,
         'pf4j_discover_ingest', 'classified', 'phase_4j_migration',
         'Tithe/charitable charge on Discover Tithe CC')
      RETURNING id INTO v_je_id;
      INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
      VALUES (v_je_id, v_agency_id, v_tithe_coa_id,       v_amt, 0, v_txn.description, v_pers_id);
      INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
      VALUES (v_je_id, v_agency_id, v_discover_coa_id,    0, v_amt, v_txn.description, v_pers_id);
    END IF;
    UPDATE public.credit_transactions SET journal_entry_id = v_je_id WHERE id = v_txn.id;
  END LOOP;

  UPDATE public.journal_lines
     SET account_id = v_transfers_coa_id
   WHERE journal_entry_id IN (
     SELECT je.id FROM public.journal_entries je
     JOIN public.bank_transactions bt ON bt.journal_entry_id = je.id
     WHERE bt.business_entity_id = v_pers_id AND bt.description ILIKE '%DISCOVER%'
   )
     AND account_id = v_susp_out_id;

  UPDATE public.journal_entries je
     SET classification_status = 'classified',
         classified_by = 'pf4j_discover_ingest',
         classified_at = NOW(),
         memo = COALESCE(memo || ' | ', '') || 'Reclass: bank withdrawal to Discover Tithe CC = CC payment (Internal Transfers)'
   WHERE je.id IN (
     SELECT bt.journal_entry_id FROM public.bank_transactions bt
     WHERE bt.business_entity_id = v_pers_id AND bt.description ILIKE '%DISCOVER%'
   );
END $pf4j$;

INSERT INTO public.gl_classification_rules
  (agency_id, rule_name, match_priority, match_payee_regex, match_source_account, match_direction,
   debit_account_code, credit_account_code, sub_category_label, confidence, source, is_active)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'Reasonable Faith -> Tithe & Charitable',       100, '(?i)REASONABLE\s+FAITH',              NULL, 'debit', 'COA-PERSONAL-9700', '__SOURCE__', 'Tithe & Charitable', 'exact', 'pf4j_discover_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Vault Fostering -> Tithe & Charitable',        100, '(?i)VAULT\s+FOSTERING',               NULL, 'debit', 'COA-PERSONAL-9700', '__SOURCE__', 'Tithe & Charitable', 'exact', 'pf4j_discover_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'GIV Christ Community -> Tithe & Charitable',   100, '(?i)GIV\*CHRIST\s+COMMUNITY',         NULL, 'debit', 'COA-PERSONAL-9700', '__SOURCE__', 'Tithe & Charitable', 'exact', 'pf4j_discover_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'PayPal Actmin -> Tithe & Charitable',          100, '(?i)PAYPAL\s*\*?\s*ACTMIN',           NULL, 'debit', 'COA-PERSONAL-9700', '__SOURCE__', 'Tithe & Charitable', 'exact', 'pf4j_discover_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Amazon on Discover -> Tithe (Vault donations)', 110, '(?i)AMAZON|Amazon\.com',            'COA-PERSONAL-CC-3208', 'debit', 'COA-PERSONAL-9700', '__SOURCE__', 'Tithe & Charitable', 'exact', 'pf4j_discover_seed', true);
