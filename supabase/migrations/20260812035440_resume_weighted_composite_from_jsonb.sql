-- Shared weighted-score helper for the resume layer. Mirrors verdict_resume's
-- construct math exactly (resume_capability / resume_character /
-- resume_commitment weighted 20/40/40 via hiregauge_layer_composite_weights),
-- but takes a resume_analysis jsonb blob directly instead of a candidate_id.
--
-- Needed because verdict_resume(candidate_id) reads hiring_candidates from
-- the table -- inside a BEFORE trigger that reads NEW.resume_analysis, a
-- table read for the same row returns the OLD (pre-write) data, not NEW.
-- This function works off the jsonb value in hand, so it is safe to call
-- from both a BEFORE trigger (on NEW.resume_analysis) and a normal SELECT
-- (on hc.resume_analysis) with identical results.
--
-- Peter-approved 2026-08-11 (open_question 7e377007, part 2): both
-- send_v1_assessment_invitations and auto_decline_on_resume_score
-- previously gated on resume_analysis->>'avg' (a plain, unweighted mean of
-- the 13 signals). The published verdict bands (70/50) are defined against
-- the WEIGHTED score -- Capability 20%, Character 40%, Commitment 40% -- so
-- for lopsided profiles the two numbers diverge and decisions were running
-- on the wrong one. This function is the single source of truth for that
-- weighted number going forward.
CREATE OR REPLACE FUNCTION public.resume_weighted_composite(p_resume_analysis jsonb)
RETURNS numeric
LANGUAGE sql
STABLE
AS $function$
  WITH sig AS (
    SELECT
      (p_resume_analysis->'signals'->'autonomy'->>'score')::numeric AS autonomy,
      (p_resume_analysis->'signals'->'leadership_emergence'->>'score')::numeric AS leadership_emergence,
      (p_resume_analysis->'signals'->'interpersonal_substrate'->>'score')::numeric AS interpersonal_substrate,
      (p_resume_analysis->'signals'->'honesty'->>'score')::numeric AS honesty,
      (p_resume_analysis->'signals'->'concern_for_others'->>'score')::numeric AS concern_for_others,
      (p_resume_analysis->'signals'->'hard_work_ethic'->>'score')::numeric AS hard_work_ethic,
      (p_resume_analysis->'signals'->'personal_responsibility'->>'score')::numeric AS personal_responsibility,
      (p_resume_analysis->'signals'->'presentation'->>'score')::numeric AS presentation,
      (p_resume_analysis->'signals'->'trajectory_direction'->>'score')::numeric AS trajectory_direction,
      (p_resume_analysis->'signals'->'coherent_pursuit'->>'score')::numeric AS coherent_pursuit,
      (p_resume_analysis->'signals'->'follow_through'->>'score')::numeric AS follow_through,
      (p_resume_analysis->'signals'->'goal_orientation'->>'score')::numeric AS goal_orientation,
      (p_resume_analysis->'signals'->'content_effort'->>'score')::numeric AS content_effort
  ),
  constructs AS (
    SELECT
      CASE WHEN autonomy IS NOT NULL AND leadership_emergence IS NOT NULL AND interpersonal_substrate IS NOT NULL
        THEN round((autonomy + leadership_emergence + interpersonal_substrate) / 3.0, 2) END AS capability,
      CASE WHEN honesty IS NOT NULL AND concern_for_others IS NOT NULL AND hard_work_ethic IS NOT NULL AND personal_responsibility IS NOT NULL
        THEN round(
          (honesty + concern_for_others + hard_work_ethic + personal_responsibility + COALESCE(presentation, 0))
          / (4.0 + CASE WHEN presentation IS NOT NULL THEN 1.0 ELSE 0.0 END), 2) END AS character,
      CASE WHEN trajectory_direction IS NOT NULL AND coherent_pursuit IS NOT NULL AND follow_through IS NOT NULL AND goal_orientation IS NOT NULL
        THEN round(
          (trajectory_direction + coherent_pursuit + follow_through + goal_orientation + COALESCE(content_effort, 0))
          / (4.0 + CASE WHEN content_effort IS NOT NULL THEN 1.0 ELSE 0.0 END), 2) END AS commitment
    FROM sig
  ),
  weights AS (
    SELECT
      max(CASE WHEN construct = 'capability' THEN weight END) AS w_cap,
      max(CASE WHEN construct = 'character'  THEN weight END) AS w_chr,
      max(CASE WHEN construct = 'commitment' THEN weight END) AS w_com
    FROM public.hiregauge_layer_composite_weights WHERE layer = 'resume'
  ),
  weighted AS (
    SELECT
      COALESCE(c.capability, 0) * COALESCE(w.w_cap, 0) * (CASE WHEN c.capability IS NOT NULL THEN 1 ELSE 0 END)
      + COALESCE(c.character, 0) * COALESCE(w.w_chr, 0) * (CASE WHEN c.character IS NOT NULL THEN 1 ELSE 0 END)
      + COALESCE(c.commitment, 0) * COALESCE(w.w_com, 0) * (CASE WHEN c.commitment IS NOT NULL THEN 1 ELSE 0 END)
        AS v_sum,
      (CASE WHEN c.capability IS NOT NULL THEN w.w_cap ELSE 0 END)
      + (CASE WHEN c.character IS NOT NULL THEN w.w_chr ELSE 0 END)
      + (CASE WHEN c.commitment IS NOT NULL THEN w.w_com ELSE 0 END)
        AS v_wsum
    FROM constructs c, weights w
  )
  SELECT CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END
  FROM weighted;
$function$;
