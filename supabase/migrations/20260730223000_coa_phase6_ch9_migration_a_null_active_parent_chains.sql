-- Phase 6 Ch9 — Migration A: null parent_account_id on all active COAs.
-- After this, no active COA has a parent chain. All subtotal logic keys off account_subtype.
-- The 74 rows being changed all pointed at 11 inactive Phase-3 folder parents (State Farm,
-- IPS - SF Comp, Alliances - SF Comp, 0001 ADMINISTRATION, 0003 MARKETING, etc.).
-- Reversible: parent chain could be reconstructed from account_master_codes if needed.

UPDATE public.chart_of_accounts
SET parent_account_id = NULL
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND is_active=true
  AND parent_account_id IS NOT NULL;
