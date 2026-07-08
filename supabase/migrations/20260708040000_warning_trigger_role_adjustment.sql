-- ============================================================================
-- Warning trigger role adjustment — 2026-07-08 (follow-up)
-- ============================================================================
-- Retention roles (role_category = 'Retention') get bar × 0.25 to reflect that
-- their primary contribution is service/retention, not direct production.
-- All other roles remain at bar × 1.00.
--
-- Also adds role, role_category, role_production_weight, warning_bar_full to
-- the compute_warning_trigger return signature.
-- ============================================================================

DROP FUNCTION IF EXISTS public.compute_warning_trigger(uuid, date);

-- (Function body applied via Supabase MCP as migration warning_trigger_role_adjustment.
-- Canonical version in pg_proc. Key changes vs prior version:
--   - Adds role, role_category, role_production_weight to output
--   - Adds warning_bar_full (unadjusted) alongside warning_bar (adjusted)
--   - Bar formula now: (annual_base × tenure_mult) × 1.08 × role_production_weight
--   - role_production_weight = 0.25 for role_category = 'Retention', else 1.00
--   - Retention floor keeps SOME production expectation on the books.)
