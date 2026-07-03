-- Hotfix: remote factor 0.85 -> 0.75 in compute_weekly_pay (matches locked retention rule)
-- Also add residual-pool columns to weekly_cpr_team_detail (Phase 1 side-by-side build)

-- Part 1: Remote factor hotfix on existing function (in-place, minimal diff)
DO $migration$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef('public.compute_weekly_pay(uuid,date)'::regprocedure) INTO v_def;
  v_def := REPLACE(v_def, 'work_location=''remote'' THEN 0.85', 'work_location=''remote'' THEN 0.75');
  EXECUTE v_def;
END $migration$;

-- Part 2: New columns for residual-pool comp outputs (nullable, additive, non-destructive)
ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS base_salary_paid   numeric,
  ADD COLUMN IF NOT EXISTS commission_paid    numeric,
  ADD COLUMN IF NOT EXISTS bonus_gross        numeric,
  ADD COLUMN IF NOT EXISTS health_subtracted  numeric,
  ADD COLUMN IF NOT EXISTS bonus_net          numeric,
  ADD COLUMN IF NOT EXISTS residual_pool_diag jsonb;

COMMENT ON COLUMN public.weekly_cpr_team_detail.base_salary_paid   IS 'Residual-pool comp (7/11/2026 rollout): base salary paid this week';
COMMENT ON COLUMN public.weekly_cpr_team_detail.commission_paid    IS 'Residual-pool comp: quarterly-issued-production commission (P&C + L&H, x0.80 trim)';
COMMENT ON COLUMN public.weekly_cpr_team_detail.bonus_gross        IS 'Residual-pool comp: gross bonus share BEFORE group health subtract';
COMMENT ON COLUMN public.weekly_cpr_team_detail.health_subtracted  IS 'Residual-pool comp: agency-paid weekly group health subtract at share level';
COMMENT ON COLUMN public.weekly_cpr_team_detail.bonus_net          IS 'Residual-pool comp: net bonus share (floors at $0)';
COMMENT ON COLUMN public.weekly_cpr_team_detail.residual_pool_diag IS 'Residual-pool comp: diagnostic jsonb (pool_pct, envelope, basis breakdown, sales_points share, retention hours share)';