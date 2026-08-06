-- Peter directive 2026-08-06 (revised Phase C). Flip financial views to
-- invoker-rights so they respect the admin-gated table policies from
-- financials_admin_only_table_policies. v_income_statement excluded — already
-- invoker=true. No USING(true) policies created (that instruction is cancelled).
ALTER VIEW public.v_balance_sheet_anchored SET (security_invoker = true);
ALTER VIEW public.v_bank_balances SET (security_invoker = true);
ALTER VIEW public.v_card_balances SET (security_invoker = true);
ALTER VIEW public.v_trial_balance SET (security_invoker = true);
ALTER VIEW public.v_growth_budget_licensing_ytd SET (security_invoker = true);
ALTER VIEW public.v_growth_budget_full_ytd SET (security_invoker = true);
ALTER VIEW public.v_entity_hierarchy SET (security_invoker = true);
ALTER VIEW public.v_weekly_cash_position SET (security_invoker = true);
ALTER VIEW public.v_projected_account_balance SET (security_invoker = true);
ALTER VIEW public.v_bank_register_coding_questions SET (security_invoker = true);
ALTER VIEW public.v_ledger_dup_candidates SET (security_invoker = true);
