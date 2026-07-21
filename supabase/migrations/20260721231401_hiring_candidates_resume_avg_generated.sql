-- Adds resume_avg: null-aware average of the 11 res_* dimension scores (0-100 scale).
-- Returns NULL when all 11 are NULL; otherwise averages the populated dimensions.
ALTER TABLE public.hiring_candidates
ADD COLUMN IF NOT EXISTS resume_avg numeric GENERATED ALWAYS AS (
  CASE
    WHEN res_autonomy_score IS NULL AND res_leadership_emergence_score IS NULL
      AND res_interpersonal_substrate_score IS NULL AND res_honesty_score IS NULL
      AND res_concern_for_others_score IS NULL AND res_hard_work_ethic_score IS NULL
      AND res_personal_responsibility_score IS NULL AND res_trajectory_direction_score IS NULL
      AND res_coherent_pursuit_score IS NULL AND res_follow_through_score IS NULL
      AND res_goal_orientation_score IS NULL
    THEN NULL
    ELSE ROUND((
      COALESCE(res_autonomy_score, 0) + COALESCE(res_leadership_emergence_score, 0)
      + COALESCE(res_interpersonal_substrate_score, 0) + COALESCE(res_honesty_score, 0)
      + COALESCE(res_concern_for_others_score, 0) + COALESCE(res_hard_work_ethic_score, 0)
      + COALESCE(res_personal_responsibility_score, 0) + COALESCE(res_trajectory_direction_score, 0)
      + COALESCE(res_coherent_pursuit_score, 0) + COALESCE(res_follow_through_score, 0)
      + COALESCE(res_goal_orientation_score, 0)
    )::numeric / GREATEST(
      (CASE WHEN res_autonomy_score IS NULL THEN 0 ELSE 1 END)
      + (CASE WHEN res_leadership_emergence_score IS NULL THEN 0 ELSE 1 END)
      + (CASE WHEN res_interpersonal_substrate_score IS NULL THEN 0 ELSE 1 END)
      + (CASE WHEN res_honesty_score IS NULL THEN 0 ELSE 1 END)
      + (CASE WHEN res_concern_for_others_score IS NULL THEN 0 ELSE 1 END)
      + (CASE WHEN res_hard_work_ethic_score IS NULL THEN 0 ELSE 1 END)
      + (CASE WHEN res_personal_responsibility_score IS NULL THEN 0 ELSE 1 END)
      + (CASE WHEN res_trajectory_direction_score IS NULL THEN 0 ELSE 1 END)
      + (CASE WHEN res_coherent_pursuit_score IS NULL THEN 0 ELSE 1 END)
      + (CASE WHEN res_follow_through_score IS NULL THEN 0 ELSE 1 END)
      + (CASE WHEN res_goal_orientation_score IS NULL THEN 0 ELSE 1 END), 1))
  END
) STORED;
