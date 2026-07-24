-- SUPERSEDED by 20260724041430_hiregauge_cts_competency_v2_batch6_orphans_three_functions.sql
--
-- Original content of this file (committed by a concurrent Claude session) created v2 wrappers
-- for handles_rejection, dials_cold_calls, and prospects_in_community using copy-pasted regression
-- coefficients from unrelated competencies (handles_objections, listens_discovers_needs) as their
-- "base" formulas. This was clinically wrong — these competencies are structurally different from
-- their donor formulas, and no v1 helper ever existed for orphans to preserve verbatim from.
--
-- The correct v2 functions (with clinically-derived hand-crafted base formulas per competency)
-- were shipped in migration 20260724041430. That migration replaces whatever this file created,
-- so end-state after a fresh `supabase db reset` is correct.
--
-- This file is retained as a no-op solely to preserve migration ordering. Do not restore the
-- prior content.

SELECT 1 AS superseded_no_op;
