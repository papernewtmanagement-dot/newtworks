-- C2 verification: v_growth_budget_licensing_ytd returned 0 rows for owner
-- after flipping to invoker=true (expected nonzero). Reverting per instruction
-- "Owner nonzero fails on a view → revert THAT view only... needs design review."
ALTER VIEW public.v_growth_budget_licensing_ytd SET (security_invoker = false);

