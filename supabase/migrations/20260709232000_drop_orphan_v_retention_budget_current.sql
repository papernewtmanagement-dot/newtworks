-- Drop v_retention_budget_current — orphaned when RetentionBudgetSection.jsx was deleted 2026-07-09 (commit aec7f210).
-- Audit 2026-07-09: zero remaining consumers in frontend (all src/**), edge functions (supabase/functions/**),
-- or other DB objects (pg_depend confirms zero dependers).
--
-- retention_budget_schedule table and compute_retention_budget_weekly function stay — both still live via CPRDetail.jsx
-- and weekly_cpr_compute_outcome→write_weekly_pay chain. Migration off write_weekly_pay to write_weekly_comp_v2
-- for the automation path is a separate future cleanup.

DROP VIEW IF EXISTS public.v_retention_budget_current;
