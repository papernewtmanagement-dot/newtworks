
-- Drop the trigger from journal_lines (the column is going away)
DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.journal_lines;

-- Drop redundant columns
ALTER TABLE public.journal_entries DROP COLUMN IF EXISTS business_entity_id;
ALTER TABLE public.journal_lines   DROP COLUMN IF EXISTS business_entity_id;

-- Leave the trigger function intact for now — 13 other tables still use it
-- (chart_of_accounts, account_starting_balances, opening_balances, envelope_budget_targets,
--  bank_accounts, bank_account_map, bank_transactions, bank_register_preliminary,
--  bank_register_weekly_snapshot, credit_accounts, credit_transactions, payroll_runs,
--  payroll_detail). On those tables, business_entity_id is the LEGITIMATE column
--  (each of those tables genuinely owns entity assignment). Whether it should
--  default to agency there is a separate question about writer correctness,
--  outside the scope of the JE/JL redundancy cleanup.

