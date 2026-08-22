ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS res_subsignals;

ALTER TABLE public.hiring_candidates
  DROP COLUMN IF EXISTS res_composite,
  DROP COLUMN IF EXISTS res_nature,
  DROP COLUMN IF EXISTS res_nurture,
  DROP COLUMN IF EXISTS res_drivers;

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
