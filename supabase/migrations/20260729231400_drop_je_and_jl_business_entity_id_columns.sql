-- 2026-07-29: Drop redundant JE/JL business_entity_id columns.
-- Single source of truth: chart_of_accounts.business_entity_id, reached via
-- journal_lines.account_id -> chart_of_accounts.
-- All consumers migrated in prior migrations same session (P&L functions —
-- Thread B rewrite; v_balance_sheet_anchored; pair_eriosto_on_smvc_credit;
-- payroll_gl_writer; get_payroll_run_drilldown; Financials.jsx frontend).

DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.journal_lines;

ALTER TABLE public.journal_entries DROP COLUMN IF EXISTS business_entity_id;
ALTER TABLE public.journal_lines   DROP COLUMN IF EXISTS business_entity_id;

-- Trigger function tg_default_business_entity_from_agency is intentionally left
-- in place. It still fires on 13 other tables (chart_of_accounts, bank_accounts,
-- credit_accounts, etc.) where business_entity_id is the LEGITIMATE column.
-- Whether it should default to agency on those tables is a separate concern.
