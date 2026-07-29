-- Retire tg_default_business_entity_from_agency and enforce business_entity_id NOT NULL on
-- the 13 entity-owning tables. Every writer sets entity explicitly today (audit 2026-07-29),
-- so the trigger's silent b2222222 default was creating poisoning risk without adding value.
-- NOT NULL replaces the trigger's "safety net" with a hard guarantee.

-- 1. Drop the trigger from all 13 tables.
DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.bank_accounts;
DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.credit_accounts;
DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.chart_of_accounts;
DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.bank_transactions;
DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.credit_transactions;
DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.payroll_runs;
DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.payroll_detail;
DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.opening_balances;
DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.account_starting_balances;
DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.envelope_budget_targets;
DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.bank_account_map;
DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.bank_register_preliminary;
DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.bank_register_weekly_snapshot;

-- 2. Enforce NOT NULL on business_entity_id (0 nulls verified 2026-07-29 pre-flight).
ALTER TABLE public.bank_accounts                  ALTER COLUMN business_entity_id SET NOT NULL;
ALTER TABLE public.credit_accounts                ALTER COLUMN business_entity_id SET NOT NULL;
ALTER TABLE public.chart_of_accounts              ALTER COLUMN business_entity_id SET NOT NULL;
ALTER TABLE public.bank_transactions              ALTER COLUMN business_entity_id SET NOT NULL;
ALTER TABLE public.credit_transactions            ALTER COLUMN business_entity_id SET NOT NULL;
ALTER TABLE public.payroll_runs                   ALTER COLUMN business_entity_id SET NOT NULL;
ALTER TABLE public.payroll_detail                 ALTER COLUMN business_entity_id SET NOT NULL;
ALTER TABLE public.opening_balances               ALTER COLUMN business_entity_id SET NOT NULL;
ALTER TABLE public.account_starting_balances      ALTER COLUMN business_entity_id SET NOT NULL;
ALTER TABLE public.envelope_budget_targets        ALTER COLUMN business_entity_id SET NOT NULL;
ALTER TABLE public.bank_account_map               ALTER COLUMN business_entity_id SET NOT NULL;
ALTER TABLE public.bank_register_preliminary      ALTER COLUMN business_entity_id SET NOT NULL;
ALTER TABLE public.bank_register_weekly_snapshot  ALTER COLUMN business_entity_id SET NOT NULL;

-- 3. Drop the function now that no triggers reference it.
DROP FUNCTION IF EXISTS public.tg_default_business_entity_from_agency();
