-- Phase 7b: Peter directive 2026-07-17 — all existing data currently on
-- PaperNewt (b1111111) retags to Peter Story State Farm (b2222222). Peter
-- will selectively move specific rows/patterns to other entities (back to
-- PaperNewt for parent-company overhead, or to Story Business Admin / Eriosto
-- as applicable) as needed.
--
-- CARVEOUTS: payroll_runs + payroll_detail stay on PaperNewt per the
-- two-entity payroll convention (core_principle financial_health
-- "two_entity_payroll": PaperNewt is the S-Corp employer of record; payroll
-- routes there structurally). Core principles outrank blanket directives.
--
-- All other entity-tagged rows on b1111111 → b2222222 in a single migration
-- so the retag is atomic (no partial visibility to any reader).
--
-- After this migration, at Peter Story State Farm view all financial data
-- appears; at PaperNewt view it still appears via the subtree filter (agency
-- is a child of PaperNewt); at Personal (root) view it appears through both
-- parents. Payroll stays visible only at PaperNewt/Personal views.

DO $$
DECLARE
  v_from uuid := 'b1111111-1111-1111-1111-111111111111';
  v_to   uuid := 'b2222222-2222-2222-2222-222222222222';
  v_touched_je int; v_touched_jl int; v_touched_pypl int;
  v_touched_ob int; v_touched_coa int; v_touched_asb int;
  v_touched_ba int; v_touched_bam int; v_touched_bt int;
  v_touched_brp int; v_touched_brws int;
  v_touched_ca int; v_touched_ct int; v_touched_ebt int;
BEGIN
  UPDATE journal_entries         SET business_entity_id=v_to WHERE business_entity_id=v_from;  GET DIAGNOSTICS v_touched_je   = ROW_COUNT;
  UPDATE journal_lines           SET business_entity_id=v_to WHERE business_entity_id=v_from;  GET DIAGNOSTICS v_touched_jl   = ROW_COUNT;
  UPDATE prior_year_pl           SET business_entity_id=v_to WHERE business_entity_id=v_from;  GET DIAGNOSTICS v_touched_pypl = ROW_COUNT;
  UPDATE opening_balances        SET business_entity_id=v_to WHERE business_entity_id=v_from;  GET DIAGNOSTICS v_touched_ob   = ROW_COUNT;
  UPDATE chart_of_accounts       SET business_entity_id=v_to WHERE business_entity_id=v_from;  GET DIAGNOSTICS v_touched_coa  = ROW_COUNT;
  UPDATE account_starting_balances SET business_entity_id=v_to WHERE business_entity_id=v_from; GET DIAGNOSTICS v_touched_asb = ROW_COUNT;
  UPDATE bank_accounts           SET business_entity_id=v_to WHERE business_entity_id=v_from;  GET DIAGNOSTICS v_touched_ba   = ROW_COUNT;
  UPDATE bank_account_map        SET business_entity_id=v_to WHERE business_entity_id=v_from;  GET DIAGNOSTICS v_touched_bam  = ROW_COUNT;
  UPDATE bank_transactions       SET business_entity_id=v_to WHERE business_entity_id=v_from;  GET DIAGNOSTICS v_touched_bt   = ROW_COUNT;
  UPDATE bank_register_preliminary   SET business_entity_id=v_to WHERE business_entity_id=v_from; GET DIAGNOSTICS v_touched_brp = ROW_COUNT;
  UPDATE bank_register_weekly_snapshot SET business_entity_id=v_to WHERE business_entity_id=v_from; GET DIAGNOSTICS v_touched_brws = ROW_COUNT;
  UPDATE credit_accounts         SET business_entity_id=v_to WHERE business_entity_id=v_from;  GET DIAGNOSTICS v_touched_ca   = ROW_COUNT;
  UPDATE credit_transactions     SET business_entity_id=v_to WHERE business_entity_id=v_from;  GET DIAGNOSTICS v_touched_ct   = ROW_COUNT;
  UPDATE envelope_budget_targets SET business_entity_id=v_to WHERE business_entity_id=v_from;  GET DIAGNOSTICS v_touched_ebt  = ROW_COUNT;

  RAISE NOTICE 'Retag summary (PaperNewt -> Peter Story State Farm):';
  RAISE NOTICE '  journal_entries: %',           v_touched_je;
  RAISE NOTICE '  journal_lines: %',             v_touched_jl;
  RAISE NOTICE '  prior_year_pl: %',             v_touched_pypl;
  RAISE NOTICE '  opening_balances: %',          v_touched_ob;
  RAISE NOTICE '  chart_of_accounts: %',         v_touched_coa;
  RAISE NOTICE '  account_starting_balances: %', v_touched_asb;
  RAISE NOTICE '  bank_accounts: %',             v_touched_ba;
  RAISE NOTICE '  bank_account_map: %',          v_touched_bam;
  RAISE NOTICE '  bank_transactions: %',         v_touched_bt;
  RAISE NOTICE '  bank_register_preliminary: %', v_touched_brp;
  RAISE NOTICE '  bank_register_weekly_snapshot: %', v_touched_brws;
  RAISE NOTICE '  credit_accounts: %',           v_touched_ca;
  RAISE NOTICE '  credit_transactions: %',       v_touched_ct;
  RAISE NOTICE '  envelope_budget_targets: %',   v_touched_ebt;
  RAISE NOTICE 'CARVEOUT (unchanged, stays PaperNewt per two-entity payroll convention):';
  RAISE NOTICE '  payroll_runs, payroll_detail';
END $$;
