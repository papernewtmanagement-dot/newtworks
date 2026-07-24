-- Move "Presentation" from Drivers construct to Nurture construct per Peter directive 2026-07-24.
-- Reasoning: presentation reflects attention-to-detail + pride-in-work-craft (Nurture territory: habits and traits built over time),
-- not role-specific motivation (Drivers). Content Effort stays in Drivers because it IS role-specific motivation.
-- Framework stays at 13 signals total. Drivers goes back to 5 sub-signals (trajectory + coherent + follow + goal + content_effort).
-- Nurture goes 4 -> 5 sub-signals (honesty + concern + hard_work_ethic + personal_resp + presentation).
--
-- No score changes needed for the 21 candidates — signals.presentation key stays as-is; only the cell fns changed which construct reads it.

-- 1. Rename hiregauge_rules row "Drivers: Presentation" -> "Nurture: Presentation" with Nurture framing + weighting caveat (full rubric in applied migration)
-- 2. Revert 4 Drivers sub-signal rows: "1 of 6" -> "1 of 5", notes updated
-- 3. Update Content Effort row: "1 of 6" -> "1 of 5", note updated to "Sub-signal 5 of 5"
-- 4. Update 4 Nurture sub-signal rows: "1 of 4" -> "1 of 5", notes updated
-- 5. resume_drivers: revert to 5 sub-signals (no presentation)
-- 6. resume_nurture: add presentation as 5th sub-signal (backward-compatible NULL guard)

CREATE OR REPLACE FUNCTION public.resume_drivers(p_candidate_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  WITH s AS (
    SELECT
      (hc.resume_analysis->'signals'->'trajectory_direction'->>'score')::numeric AS trajectory_direction,
      (hc.resume_analysis->'signals'->'coherent_pursuit'->>'score')::numeric     AS coherent_pursuit,
      (hc.resume_analysis->'signals'->'follow_through'->>'score')::numeric       AS follow_through,
      (hc.resume_analysis->'signals'->'goal_orientation'->>'score')::numeric     AS goal_orientation,
      (hc.resume_analysis->'signals'->'content_effort'->>'score')::numeric       AS content_effort
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
  )
  SELECT round(
    (trajectory_direction + coherent_pursuit + follow_through + goal_orientation + COALESCE(content_effort, 0))
    / (4.0 + CASE WHEN content_effort IS NOT NULL THEN 1.0 ELSE 0.0 END),
    2)
  FROM s
  WHERE trajectory_direction IS NOT NULL
    AND coherent_pursuit    IS NOT NULL
    AND follow_through      IS NOT NULL
    AND goal_orientation    IS NOT NULL;
$function$;

CREATE OR REPLACE FUNCTION public.resume_nurture(p_candidate_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  WITH s AS (
    SELECT
      (hc.resume_analysis->'signals'->'honesty'->>'score')::numeric                 AS honesty,
      (hc.resume_analysis->'signals'->'concern_for_others'->>'score')::numeric      AS concern_for_others,
      (hc.resume_analysis->'signals'->'hard_work_ethic'->>'score')::numeric         AS hard_work_ethic,
      (hc.resume_analysis->'signals'->'personal_responsibility'->>'score')::numeric AS personal_responsibility,
      (hc.resume_analysis->'signals'->'presentation'->>'score')::numeric            AS presentation
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
  )
  SELECT round(
    (honesty + concern_for_others + hard_work_ethic + personal_responsibility + COALESCE(presentation, 0))
    / (4.0 + CASE WHEN presentation IS NOT NULL THEN 1.0 ELSE 0.0 END),
    2)
  FROM s
  WHERE honesty                 IS NOT NULL
    AND concern_for_others      IS NOT NULL
    AND hard_work_ethic         IS NOT NULL
    AND personal_responsibility IS NOT NULL;
$function$;
