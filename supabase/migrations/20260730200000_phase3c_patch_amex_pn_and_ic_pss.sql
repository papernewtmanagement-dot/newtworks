-- =====================================================================
-- Phase 3C: Post-verification patch
--
-- Two rows missed by Migrations A + B, discovered during final scan:
--   1. PaperNewt COA-009 "AMEX - Discretionary" (454 journal lines) —
--      active credit card that needed a PaperNewt-specific master code.
--      Phase 1-2 seeded 2120 as "PSS — AMEX Discretionary" but did not
--      seed the PaperNewt AMEX slot. Adding 2141.
--   2. PSS COA-IC-001 "Due to PaperNewt LLC" (46 journal lines) —
--      the mirror of PaperNewt's COA-IC-002 "Due from PSS", which was
--      rekeyed to 1901 in Migration B. This PSS-side payable rekeys
--      to master 2902 (shared_concept: Due to PaperNewt LLC).
--
-- Author: Claude (Phase 3 CoA overhaul)
-- Date:   2026-07-30
-- =====================================================================

INSERT INTO public.account_master_codes (agency_id, code, name, account_type, account_subtype, code_kind)
VALUES ('126794dd-25ff-47d2-a436-724499733365', '2141', 'PaperNewt — AMEX Discretionary', 'liability', 'credit_card', 'entity_specific')
ON CONFLICT (agency_id, code) DO NOTHING;

CREATE OR REPLACE FUNCTION public._phase3_rekey_account(
  p_agency uuid, p_old_code text, p_new_code text
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE public.chart_of_accounts SET account_code = p_new_code
   WHERE agency_id = p_agency AND account_code = p_old_code;
  UPDATE public.gl_classification_rules SET debit_account_code = p_new_code
   WHERE agency_id = p_agency AND debit_account_code = p_old_code;
  UPDATE public.gl_classification_rules SET credit_account_code = p_new_code
   WHERE agency_id = p_agency AND credit_account_code = p_old_code;
  UPDATE public.statement_balances SET account_code = p_new_code
   WHERE agency_id = p_agency AND account_code = p_old_code;
  UPDATE public.opening_balances SET account_code = p_new_code
   WHERE agency_id = p_agency AND account_code = p_old_code;
  UPDATE public.documents SET source_account_code = p_new_code
   WHERE agency_id = p_agency AND source_account_code = p_old_code;
  UPDATE public.gmail_label_classification_map SET source_account_code = p_new_code
   WHERE agency_id = p_agency AND source_account_code = p_old_code;
  UPDATE public.envelope_budget_targets SET account_code = p_new_code
   WHERE agency_id = p_agency AND account_code = p_old_code;
  UPDATE public.prior_year_pl_account_map SET newtworks_account_code = p_new_code
   WHERE agency_id = p_agency AND newtworks_account_code = p_old_code;
END;
$$;

SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-IC-001', '2902');
SELECT public._phase3_rekey_account('126794dd-25ff-47d2-a436-724499733365', 'COA-009', '2141');

DROP FUNCTION IF EXISTS public._phase3_rekey_account(uuid, text, text);
