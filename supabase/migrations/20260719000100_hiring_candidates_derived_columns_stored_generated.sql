-- Convert res_nature, res_nurture, res_drivers, res_composite to STORED GENERATED
-- columns. Peter directive 2026-07-18 extension: derived values must not drift
-- from source. Verdict already dropped (view-only). Constructs + composite now
-- computed by the DB at write time — cannot be manually set, cannot drift.
--
-- Sole source of truth = the 11 sub-signal score columns:
--   3 Nature: res_autonomy, res_leadership_emergence, res_interpersonal_substrate
--   4 Nurture: res_honesty, res_concern_for_others, res_hard_work_ethic, res_personal_responsibility
--   4 Drivers: res_trajectory_direction, res_coherent_pursuit, res_follow_through, res_goal_orientation
--
-- Derivation formulas (from hiregauge_rules resume_score_rubric Composite Config):
--   res_nature   = mean of its 3 sub-signals
--   res_nurture  = mean of its 4 sub-signals
--   res_drivers  = mean of its 4 sub-signals
--   res_composite = 0.35*nature + 0.30*nurture + 0.35*drivers
--
-- Composite expression references sub-signals directly (not the other generated
-- columns) — PostgreSQL 12+ prohibits GENERATED column referencing another
-- GENERATED column.
--
-- Consumer audit clean 2026-07-18:
--   Frontend: CandidateDetail.jsx reads via detail.res_composite / .res_nature /
--             .res_nurture / .res_drivers — column names unchanged, reads keep
--             working.
--   DB: hiregauge_three_construct_verdict + _by_role read res_nature/_nurture/
--       _drivers as inputs to their layer math — reads keep working.
--       No SQL function writes these columns.
--   res_subsignals JSONB: zero consumers after frontend cutover (mig 20260718230100).
--
-- Workflow impact: in-chat scoring UPDATE statements must NOT include SET clauses
-- for res_nature / res_nurture / res_drivers / res_composite — those columns are
-- read-only. Only the 11 sub-signal columns get set. Derived values auto-flow.

-- Drop unused JSONB legacy column.
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS res_subsignals;

-- Drop the four stored derived columns.
ALTER TABLE public.hiring_candidates
  DROP COLUMN IF EXISTS res_composite,
  DROP COLUMN IF EXISTS res_nature,
  DROP COLUMN IF EXISTS res_nurture,
  DROP COLUMN IF EXISTS res_drivers;

-- Re-add as STORED GENERATED. Values compute at write time on any UPDATE to a
-- sub-signal column. Partial data (any sub-signal NULL) yields NULL for the
-- derived column via SQL NULL propagation — correct behavior.
ALTER TABLE public.hiring_candidates
  ADD COLUMN res_nature numeric GENERATED ALWAYS AS (
    ROUND(
      (res_autonomy_score
       + res_leadership_emergence_score
       + res_interpersonal_substrate_score)::numeric / 3.0
    , 2)
  ) STORED,
  ADD COLUMN res_nurture numeric GENERATED ALWAYS AS (
    ROUND(
      (res_honesty_score
       + res_concern_for_others_score
       + res_hard_work_ethic_score
       + res_personal_responsibility_score)::numeric / 4.0
    , 2)
  ) STORED,
  ADD COLUMN res_drivers numeric GENERATED ALWAYS AS (
    ROUND(
      (res_trajectory_direction_score
       + res_coherent_pursuit_score
       + res_follow_through_score
       + res_goal_orientation_score)::numeric / 4.0
    , 2)
  ) STORED,
  ADD COLUMN res_composite numeric GENERATED ALWAYS AS (
    ROUND(
      0.35 * ((res_autonomy_score
               + res_leadership_emergence_score
               + res_interpersonal_substrate_score)::numeric / 3.0)
      + 0.30 * ((res_honesty_score
                 + res_concern_for_others_score
                 + res_hard_work_ethic_score
                 + res_personal_responsibility_score)::numeric / 4.0)
      + 0.35 * ((res_trajectory_direction_score
                 + res_coherent_pursuit_score
                 + res_follow_through_score
                 + res_goal_orientation_score)::numeric / 4.0)
    , 2)
  ) STORED;

COMMENT ON COLUMN public.hiring_candidates.res_nature IS
  'STORED GENERATED. Mean of Nature sub-signal scores (Autonomy, Leadership Emergence, Interpersonal Substrate). Read-only. To change, edit sub-signal columns.';
COMMENT ON COLUMN public.hiring_candidates.res_nurture IS
  'STORED GENERATED. Mean of Nurture sub-signal scores (Honesty, Concern for Others, Hard Work Ethic, Personal Responsibility). Read-only.';
COMMENT ON COLUMN public.hiring_candidates.res_drivers IS
  'STORED GENERATED. Mean of Drivers sub-signal scores (Trajectory Direction, Coherent Pursuit, Follow-Through, Goal Orientation). Read-only.';
COMMENT ON COLUMN public.hiring_candidates.res_composite IS
  'STORED GENERATED. 0.35*nature + 0.30*nurture + 0.35*drivers, computed from sub-signal columns directly. Read-only. Verdict bands: >=7.0 pass, >=5.0 consider, <5.0 decline (computed on view, not stored).';
