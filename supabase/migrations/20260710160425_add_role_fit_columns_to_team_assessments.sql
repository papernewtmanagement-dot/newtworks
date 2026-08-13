-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-10 16:04:25 UTC (ledger name: add_role_fit_columns_to_team_assessments) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260710160425.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Add per-role OS score columns + service_sales_competencies jsonb
-- Existing: cts_only_score, cts_plus_lss_score, sales_competencies (all = sales role)
--           service_competencies, agent_competencies (previously unused)
-- Semantic: agent_competencies now holds "aspirant" role competencies
ALTER TABLE public.team_assessments
  ADD COLUMN IF NOT EXISTS service_os_only int,
  ADD COLUMN IF NOT EXISTS service_os_lss int,
  ADD COLUMN IF NOT EXISTS service_sales_os_only int,
  ADD COLUMN IF NOT EXISTS service_sales_os_lss int,
  ADD COLUMN IF NOT EXISTS aspirant_os_only int,
  ADD COLUMN IF NOT EXISTS aspirant_os_lss int,
  ADD COLUMN IF NOT EXISTS service_sales_competencies jsonb;

-- Add convenience column: best-fit role based on highest OS-only score across the 4 roles
ALTER TABLE public.team_assessments
  ADD COLUMN IF NOT EXISTS best_fit_role text,
  ADD COLUMN IF NOT EXISTS best_fit_os int;

-- Sanity check
COMMENT ON COLUMN public.team_assessments.cts_only_score IS 'Sales role OS (CTS-only). Preserved for backward compat; aliased by v_team_assessment_role_fit.sales_os_only.';
COMMENT ON COLUMN public.team_assessments.cts_plus_lss_score IS 'Sales role OS (CTS+LSS). Preserved for backward compat.';
COMMENT ON COLUMN public.team_assessments.agent_competencies IS 'Aspirant (agent) role competencies as jsonb. Includes LS categorical + 5 aspirant numeric competencies (HES, BLAEWH, IFSO, CFR) alongside the 9 sales-shared competency scores computed for the aspirant weighting.';
