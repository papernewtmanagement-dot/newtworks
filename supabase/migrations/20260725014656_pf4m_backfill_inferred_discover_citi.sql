-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-25 01:46:56 UTC (ledger name: pf4m_backfill_inferred_discover_citi) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260725014656.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- =====================================================================
-- Phase 4m: Backfill inferred activity from balance math
--
-- Discover 04/28-05/27 missing statement:
--   Payment: $5,571.79 (bank-verified, 5/8 withdrawal)
--   Charges: $3,566.38 (exact, from Doc 2 closing $5,571.79 - payment + charges = Doc 6 opening $3,566.38)
--   Composition unknown — booked as single aggregate charge
--
-- Citi 1247 pre-window plug:
--   ~$308.09 of pre-Feb 2026 charges must have existed (3/19 bank payment $204.45
--   + 5/2 CC payment $103.64 with no matching charges in ingested window)
--   Composition unknown — booked as single aggregate charge dated 2/1/2026
-- =====================================================================

DO $pf4m$
DECLARE
  v_agency_id UUID := '126794dd-25ff-47d2-a436-724499733365';
  v_pers_id UUID := 'b3333333-3333-3333-3333-333333333333';
  v_pn_id UUID := 'b1111111-1111-1111-1111-111111111111';
  v_discover_coa_id UUID;
  v_citi_pn_coa_id UUID;
  v_tithe_coa_id UUID;
  v_transfers_coa_id UUID;
  v_pn_cogs_id UUID;
  v_pn_owner_contrib_id UUID;
  v_je_id UUID;
BEGIN
  SELECT id INTO v_discover_coa_id     FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-CC-3208';
  SELECT id INTO v_citi_pn_coa_id      FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PN-CC-1247';
  SELECT id INTO v_tithe_coa_id        FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-9700';
  SELECT id INTO v_transfers_coa_id    FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PERSONAL-9990';
  SELECT id INTO v_pn_cogs_id          FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-PN-COGS-PRINT';

  -- 1. Discover missing month: aggregate CHARGES for $3,566.38 (composition unknown)
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
  VALUES (v_agency_id, v_pers_id, '2026-05-15', 'personal_credit',
          'DISCOVER: Aggregate tithe charges 04/28-05/27 (statement not obtained)',
          'pf4m_discover_inferred', 'classified', 'phase_4m_migration',
          'INFERRED from balance math: Doc 2 closing $5,571.79 - $5,571.79 payment + $3,566.38 charges = Doc 6 opening $3,566.38. Composition unknown; likely 4 typical tithe recipients (Reasonable Faith, Vault Fostering, Christ Community, Actmin). True up when statement obtained.')
  RETURNING id INTO v_je_id;
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
  VALUES (v_je_id, v_agency_id, v_tithe_coa_id, 3566.38, 0, 'Aggregate tithe charges 04/28-05/27', v_pers_id);
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
  VALUES (v_je_id, v_agency_id, v_discover_coa_id, 0, 3566.38, 'Aggregate tithe charges 04/28-05/27', v_pers_id);

  -- 2. Discover missing month: PAYMENT $5,571.79 (bank-verified)
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
  VALUES (v_agency_id, v_pers_id, '2026-05-06', 'personal_credit',
          'DISCOVER: INTERNET PAYMENT - THANK YOU (04/28-05/27 statement payoff)',
          'pf4m_discover_inferred', 'classified', 'phase_4m_migration',
          'Bank-verified payment (bank 5/8 $5,571.79 to Discover); CC-side date inferred at 5/6 based on typical 2-day bank/CC lag')
  RETURNING id INTO v_je_id;
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
  VALUES (v_je_id, v_agency_id, v_discover_coa_id, 5571.79, 0, 'Payment received on Discover Tithe CC', v_pers_id);
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
  VALUES (v_je_id, v_agency_id, v_transfers_coa_id, 0, 5571.79, 'Payment received on Discover Tithe CC', v_pers_id);

  -- 3. Citi pre-window plug: aggregate PN Print COGS charge of $308.09
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
  VALUES (v_agency_id, v_pn_id, '2026-02-01', 'business_credit',
          'PN CITI 1247: Pre-February 2026 aggregate charges (statement not obtained)',
          'pf4m_citi_pn_plug', 'classified', 'phase_4m_migration',
          'INFERRED: bank paid $204.45 on 3/19 + CC received $103.64 on 5/2, both without matching recorded charges. Total $308.09 of pre-Feb Citi charges must have existed. Composition unknown; likely ND4C Houston pattern. True up when statement obtained.')
  RETURNING id INTO v_je_id;
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
  VALUES (v_je_id, v_agency_id, v_pn_cogs_id, 308.09, 0, 'Aggregate pre-Feb 2026 PN Citi charges', v_pn_id);
  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
  VALUES (v_je_id, v_agency_id, v_citi_pn_coa_id, 0, 308.09, 'Aggregate pre-Feb 2026 PN Citi charges', v_pn_id);
END $pf4m$;
