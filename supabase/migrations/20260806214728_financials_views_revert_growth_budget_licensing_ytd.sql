-- C2 verification: v_growth_budget_licensing_ytd returned 0 rows for owner
-- after flipping to invoker=true (expected nonzero). Reverting per instruction
-- "Owner nonzero fails on a view → revert THAT view only... needs design review."
-- NOTE: superseded same session — Peter's thread confirmed this was a false
-- negative (0 rows is correct even at service-role baseline, no licensing
-- journal entries YTD) and restored invoker=true via financials_growth_budget_admin_gate
-- (commit 42e7fe5f). Kept in migration history for an accurate audit trail.
ALTER VIEW public.v_growth_budget_licensing_ytd SET (security_invoker = false);
