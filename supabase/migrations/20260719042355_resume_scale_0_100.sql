-- Migration: resume_scale_0_100
-- Applied: 2026-07-19 (version 20260719042355)
-- Scales the HireGauge resume layer from 0-10 to 0-100.
-- Storage: numeric(5,2) (decimal up to 2 places). Display convention: rounded whole number.
-- Follow-up UPDATE in same session remapped elliptical anchor references ("and 5.", "Anchor 7") that the initial regex missed.

-- 0a. Drop check constraints (0-10 range)
ALTER TABLE public.hiring_candidates
  DROP CONSTRAINT hiring_candidates_res_autonomy_score_check,
  DROP CONSTRAINT hiring_candidates_res_coherent_pursuit_score_check,
  DROP CONSTRAINT hiring_candidates_res_concern_for_others_score_check,
  DROP CONSTRAINT hiring_candidates_res_follow_through_score_check,
  DROP CONSTRAINT hiring_candidates_res_goal_orientation_score_check,
  DROP CONSTRAINT hiring_candidates_res_hard_work_ethic_score_check,
  DROP CONSTRAINT hiring_candidates_res_honesty_score_check,
  DROP CONSTRAINT hiring_candidates_res_interpersonal_substrate_score_check,
  DROP CONSTRAINT hiring_candidates_res_leadership_emergence_score_check,
  DROP CONSTRAINT hiring_candidates_res_personal_responsibility_score_check,
  DROP CONSTRAINT hiring_candidates_res_trajectory_direction_score_check;

-- 0b. Drop v_hiring_candidates view (blocks ALTER COLUMN on its dependencies)
DROP VIEW IF EXISTS public.v_hiring_candidates;

-- 1. Convert 11 sub-signal score columns from smallint to numeric(5,2)
ALTER TABLE public.hiring_candidates
  ALTER COLUMN res_autonomy_score TYPE numeric(5,2),
  ALTER COLUMN res_leadership_emergence_score TYPE numeric(5,2),
  ALTER COLUMN res_interpersonal_substrate_score TYPE numeric(5,2),
  ALTER COLUMN res_honesty_score TYPE numeric(5,2),
  ALTER COLUMN res_concern_for_others_score TYPE numeric(5,2),
  ALTER COLUMN res_hard_work_ethic_score TYPE numeric(5,2),
  ALTER COLUMN res_personal_responsibility_score TYPE numeric(5,2),
  ALTER COLUMN res_trajectory_direction_score TYPE numeric(5,2),
  ALTER COLUMN res_coherent_pursuit_score TYPE numeric(5,2),
  ALTER COLUMN res_follow_through_score TYPE numeric(5,2),
  ALTER COLUMN res_goal_orientation_score TYPE numeric(5,2);

-- 2. Multiply all existing scored candidates by 10
UPDATE public.hiring_candidates
SET res_autonomy_score = res_autonomy_score * 10,
    res_leadership_emergence_score = res_leadership_emergence_score * 10,
    res_interpersonal_substrate_score = res_interpersonal_substrate_score * 10,
    res_honesty_score = res_honesty_score * 10,
    res_concern_for_others_score = res_concern_for_others_score * 10,
    res_hard_work_ethic_score = res_hard_work_ethic_score * 10,
    res_personal_responsibility_score = res_personal_responsibility_score * 10,
    res_trajectory_direction_score = res_trajectory_direction_score * 10,
    res_coherent_pursuit_score = res_coherent_pursuit_score * 10,
    res_follow_through_score = res_follow_through_score * 10,
    res_goal_orientation_score = res_goal_orientation_score * 10
WHERE res_scored_at IS NOT NULL;

-- 3. Re-add check constraints on 0-100 range
ALTER TABLE public.hiring_candidates
  ADD CONSTRAINT hiring_candidates_res_autonomy_score_check CHECK (res_autonomy_score >= 0 AND res_autonomy_score <= 100),
  ADD CONSTRAINT hiring_candidates_res_coherent_pursuit_score_check CHECK (res_coherent_pursuit_score >= 0 AND res_coherent_pursuit_score <= 100),
  ADD CONSTRAINT hiring_candidates_res_concern_for_others_score_check CHECK (res_concern_for_others_score >= 0 AND res_concern_for_others_score <= 100),
  ADD CONSTRAINT hiring_candidates_res_follow_through_score_check CHECK (res_follow_through_score >= 0 AND res_follow_through_score <= 100),
  ADD CONSTRAINT hiring_candidates_res_goal_orientation_score_check CHECK (res_goal_orientation_score >= 0 AND res_goal_orientation_score <= 100),
  ADD CONSTRAINT hiring_candidates_res_hard_work_ethic_score_check CHECK (res_hard_work_ethic_score >= 0 AND res_hard_work_ethic_score <= 100),
  ADD CONSTRAINT hiring_candidates_res_honesty_score_check CHECK (res_honesty_score >= 0 AND res_honesty_score <= 100),
  ADD CONSTRAINT hiring_candidates_res_interpersonal_substrate_score_check CHECK (res_interpersonal_substrate_score >= 0 AND res_interpersonal_substrate_score <= 100),
  ADD CONSTRAINT hiring_candidates_res_leadership_emergence_score_check CHECK (res_leadership_emergence_score >= 0 AND res_leadership_emergence_score <= 100),
  ADD CONSTRAINT hiring_candidates_res_personal_responsibility_score_check CHECK (res_personal_responsibility_score >= 0 AND res_personal_responsibility_score <= 100),
  ADD CONSTRAINT hiring_candidates_res_trajectory_direction_score_check CHECK (res_trajectory_direction_score >= 0 AND res_trajectory_direction_score <= 100);

-- 4. Remap anchor JSON keys 0/3/5/7/10 -> 0/30/50/70/100 on all 11 rules
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_set(
  trait_signature,
  '{anchors}',
  jsonb_build_object(
    '0', trait_signature->'anchors'->'0',
    '30', trait_signature->'anchors'->'3',
    '50', trait_signature->'anchors'->'5',
    '70', trait_signature->'anchors'->'7',
    '100', trait_signature->'anchors'->'10'
  )
)
WHERE trait_signature ? 'anchors';

-- 5. Remap anchor references in reason text ("anchor 3" -> "anchor 30", etc.)
-- Pass 1: primary "anchor N" pattern (lowercase)
UPDATE public.hiring_candidates
SET
  res_honesty_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_honesty_reason,
    'anchor 10\M', 'anchor 100', 'g'), 'anchor 7\M', 'anchor 70', 'g'), 'anchor 5\M', 'anchor 50', 'g'), 'anchor 3\M', 'anchor 30', 'g'),
  res_concern_for_others_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_concern_for_others_reason,
    'anchor 10\M', 'anchor 100', 'g'), 'anchor 7\M', 'anchor 70', 'g'), 'anchor 5\M', 'anchor 50', 'g'), 'anchor 3\M', 'anchor 30', 'g'),
  res_hard_work_ethic_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_hard_work_ethic_reason,
    'anchor 10\M', 'anchor 100', 'g'), 'anchor 7\M', 'anchor 70', 'g'), 'anchor 5\M', 'anchor 50', 'g'), 'anchor 3\M', 'anchor 30', 'g'),
  res_personal_responsibility_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_personal_responsibility_reason,
    'anchor 10\M', 'anchor 100', 'g'), 'anchor 7\M', 'anchor 70', 'g'), 'anchor 5\M', 'anchor 50', 'g'), 'anchor 3\M', 'anchor 30', 'g'),
  res_autonomy_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_autonomy_reason,
    'anchor 10\M', 'anchor 100', 'g'), 'anchor 7\M', 'anchor 70', 'g'), 'anchor 5\M', 'anchor 50', 'g'), 'anchor 3\M', 'anchor 30', 'g'),
  res_leadership_emergence_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_leadership_emergence_reason,
    'anchor 10\M', 'anchor 100', 'g'), 'anchor 7\M', 'anchor 70', 'g'), 'anchor 5\M', 'anchor 50', 'g'), 'anchor 3\M', 'anchor 30', 'g'),
  res_interpersonal_substrate_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_interpersonal_substrate_reason,
    'anchor 10\M', 'anchor 100', 'g'), 'anchor 7\M', 'anchor 70', 'g'), 'anchor 5\M', 'anchor 50', 'g'), 'anchor 3\M', 'anchor 30', 'g'),
  res_trajectory_direction_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_trajectory_direction_reason,
    'anchor 10\M', 'anchor 100', 'g'), 'anchor 7\M', 'anchor 70', 'g'), 'anchor 5\M', 'anchor 50', 'g'), 'anchor 3\M', 'anchor 30', 'g'),
  res_coherent_pursuit_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_coherent_pursuit_reason,
    'anchor 10\M', 'anchor 100', 'g'), 'anchor 7\M', 'anchor 70', 'g'), 'anchor 5\M', 'anchor 50', 'g'), 'anchor 3\M', 'anchor 30', 'g'),
  res_follow_through_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_follow_through_reason,
    'anchor 10\M', 'anchor 100', 'g'), 'anchor 7\M', 'anchor 70', 'g'), 'anchor 5\M', 'anchor 50', 'g'), 'anchor 3\M', 'anchor 30', 'g'),
  res_goal_orientation_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_goal_orientation_reason,
    'anchor 10\M', 'anchor 100', 'g'), 'anchor 7\M', 'anchor 70', 'g'), 'anchor 5\M', 'anchor 50', 'g'), 'anchor 3\M', 'anchor 30', 'g')
WHERE res_scored_at IS NOT NULL;

-- Pass 2: capital-case "Anchor N" catches Anchor 7 (clean), etc.
UPDATE public.hiring_candidates
SET
  res_honesty_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_honesty_reason,
    '([Aa]nchor )10\M', '\1100', 'g'), '([Aa]nchor )7\M', '\170', 'g'), '([Aa]nchor )5\M', '\150', 'g'), '([Aa]nchor )3\M', '\130', 'g'),
  res_concern_for_others_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_concern_for_others_reason,
    '([Aa]nchor )10\M', '\1100', 'g'), '([Aa]nchor )7\M', '\170', 'g'), '([Aa]nchor )5\M', '\150', 'g'), '([Aa]nchor )3\M', '\130', 'g'),
  res_hard_work_ethic_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_hard_work_ethic_reason,
    '([Aa]nchor )10\M', '\1100', 'g'), '([Aa]nchor )7\M', '\170', 'g'), '([Aa]nchor )5\M', '\150', 'g'), '([Aa]nchor )3\M', '\130', 'g'),
  res_personal_responsibility_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_personal_responsibility_reason,
    '([Aa]nchor )10\M', '\1100', 'g'), '([Aa]nchor )7\M', '\170', 'g'), '([Aa]nchor )5\M', '\150', 'g'), '([Aa]nchor )3\M', '\130', 'g'),
  res_autonomy_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_autonomy_reason,
    '([Aa]nchor )10\M', '\1100', 'g'), '([Aa]nchor )7\M', '\170', 'g'), '([Aa]nchor )5\M', '\150', 'g'), '([Aa]nchor )3\M', '\130', 'g'),
  res_leadership_emergence_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_leadership_emergence_reason,
    '([Aa]nchor )10\M', '\1100', 'g'), '([Aa]nchor )7\M', '\170', 'g'), '([Aa]nchor )5\M', '\150', 'g'), '([Aa]nchor )3\M', '\130', 'g'),
  res_interpersonal_substrate_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_interpersonal_substrate_reason,
    '([Aa]nchor )10\M', '\1100', 'g'), '([Aa]nchor )7\M', '\170', 'g'), '([Aa]nchor )5\M', '\150', 'g'), '([Aa]nchor )3\M', '\130', 'g'),
  res_trajectory_direction_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_trajectory_direction_reason,
    '([Aa]nchor )10\M', '\1100', 'g'), '([Aa]nchor )7\M', '\170', 'g'), '([Aa]nchor )5\M', '\150', 'g'), '([Aa]nchor )3\M', '\130', 'g'),
  res_coherent_pursuit_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_coherent_pursuit_reason,
    '([Aa]nchor )10\M', '\1100', 'g'), '([Aa]nchor )7\M', '\170', 'g'), '([Aa]nchor )5\M', '\150', 'g'), '([Aa]nchor )3\M', '\130', 'g'),
  res_follow_through_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_follow_through_reason,
    '([Aa]nchor )10\M', '\1100', 'g'), '([Aa]nchor )7\M', '\170', 'g'), '([Aa]nchor )5\M', '\150', 'g'), '([Aa]nchor )3\M', '\130', 'g'),
  res_goal_orientation_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_goal_orientation_reason,
    '([Aa]nchor )10\M', '\1100', 'g'), '([Aa]nchor )7\M', '\170', 'g'), '([Aa]nchor )5\M', '\150', 'g'), '([Aa]nchor )3\M', '\130', 'g')
WHERE res_scored_at IS NOT NULL;

-- Pass 3: elliptical "and/or/to/between/below/above N" patterns (e.g. "and 5.", "between 3 and 5")
UPDATE public.hiring_candidates
SET
  res_honesty_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_honesty_reason,
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )10([\.,\)]|\M)', '\1100\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )7([\.,\)]|\M)', '\170\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )5([\.,\)]|\M)', '\150\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )3([\.,\)]|\M)', '\130\2', 'g'),
  res_concern_for_others_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_concern_for_others_reason,
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )10([\.,\)]|\M)', '\1100\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )7([\.,\)]|\M)', '\170\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )5([\.,\)]|\M)', '\150\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )3([\.,\)]|\M)', '\130\2', 'g'),
  res_hard_work_ethic_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_hard_work_ethic_reason,
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )10([\.,\)]|\M)', '\1100\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )7([\.,\)]|\M)', '\170\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )5([\.,\)]|\M)', '\150\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )3([\.,\)]|\M)', '\130\2', 'g'),
  res_personal_responsibility_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_personal_responsibility_reason,
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )10([\.,\)]|\M)', '\1100\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )7([\.,\)]|\M)', '\170\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )5([\.,\)]|\M)', '\150\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )3([\.,\)]|\M)', '\130\2', 'g'),
  res_autonomy_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_autonomy_reason,
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )10([\.,\)]|\M)', '\1100\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )7([\.,\)]|\M)', '\170\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )5([\.,\)]|\M)', '\150\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )3([\.,\)]|\M)', '\130\2', 'g'),
  res_leadership_emergence_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_leadership_emergence_reason,
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )10([\.,\)]|\M)', '\1100\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )7([\.,\)]|\M)', '\170\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )5([\.,\)]|\M)', '\150\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )3([\.,\)]|\M)', '\130\2', 'g'),
  res_interpersonal_substrate_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_interpersonal_substrate_reason,
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )10([\.,\)]|\M)', '\1100\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )7([\.,\)]|\M)', '\170\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )5([\.,\)]|\M)', '\150\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )3([\.,\)]|\M)', '\130\2', 'g'),
  res_trajectory_direction_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_trajectory_direction_reason,
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )10([\.,\)]|\M)', '\1100\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )7([\.,\)]|\M)', '\170\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )5([\.,\)]|\M)', '\150\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )3([\.,\)]|\M)', '\130\2', 'g'),
  res_coherent_pursuit_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_coherent_pursuit_reason,
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )10([\.,\)]|\M)', '\1100\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )7([\.,\)]|\M)', '\170\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )5([\.,\)]|\M)', '\150\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )3([\.,\)]|\M)', '\130\2', 'g'),
  res_follow_through_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_follow_through_reason,
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )10([\.,\)]|\M)', '\1100\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )7([\.,\)]|\M)', '\170\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )5([\.,\)]|\M)', '\150\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )3([\.,\)]|\M)', '\130\2', 'g'),
  res_goal_orientation_reason = regexp_replace(regexp_replace(regexp_replace(regexp_replace(res_goal_orientation_reason,
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )10([\.,\)]|\M)', '\1100\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )7([\.,\)]|\M)', '\170\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )5([\.,\)]|\M)', '\150\2', 'g'),
    '([Aa]nd |[Oo]r |[Tt]o |[Bb]etween |[Bb]elow |[Aa]bove )3([\.,\)]|\M)', '\130\2', 'g')
WHERE res_scored_at IS NOT NULL;

-- 6. Recreate v_hiring_candidates view (aggregates auto-scale from 0-100 sub-signals)
CREATE VIEW public.v_hiring_candidates AS
WITH resume_w AS (
  SELECT
    max(CASE WHEN construct='nature'  THEN weight END) AS w_nat,
    max(CASE WHEN construct='nurture' THEN weight END) AS w_nur,
    max(CASE WHEN construct='drivers' THEN weight END) AS w_dr
  FROM public.hiregauge_layer_composite_weights
  WHERE layer='resume'
)
SELECT hc.*,
  round((hc.res_autonomy_score + hc.res_leadership_emergence_score + hc.res_interpersonal_substrate_score)::numeric / 3.0, 2) AS res_nature,
  round((hc.res_honesty_score + hc.res_concern_for_others_score + hc.res_hard_work_ethic_score + hc.res_personal_responsibility_score)::numeric / 4.0, 2) AS res_nurture,
  round((hc.res_trajectory_direction_score + hc.res_coherent_pursuit_score + hc.res_follow_through_score + hc.res_goal_orientation_score)::numeric / 4.0, 2) AS res_drivers,
  round(
    rw.w_nat * ((hc.res_autonomy_score + hc.res_leadership_emergence_score + hc.res_interpersonal_substrate_score)::numeric / 3.0)
    + rw.w_nur * ((hc.res_honesty_score + hc.res_concern_for_others_score + hc.res_hard_work_ethic_score + hc.res_personal_responsibility_score)::numeric / 4.0)
    + rw.w_dr * ((hc.res_trajectory_direction_score + hc.res_coherent_pursuit_score + hc.res_follow_through_score + hc.res_goal_orientation_score)::numeric / 4.0),
    2
  ) AS res_composite
FROM public.hiring_candidates hc
CROSS JOIN resume_w rw;
