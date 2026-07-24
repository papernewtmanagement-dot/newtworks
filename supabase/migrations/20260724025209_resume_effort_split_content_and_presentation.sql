-- Split resume "Effort" signal into two distinct sub-signals per Peter directive 2026-07-24:
--   content_effort  = tailoring, specifics, quantification, role-alignment, real names (intellectual work in the writing)
--   presentation    = formatting, typos, length, layout, readability, no template-skeleton artifacts (artifact quality itself)
-- Both feed Drivers. Framework goes 12 signals -> 13 (6 in Drivers).
-- Full applied migration content (rubric text + per-candidate reasons) captured via Supabase MCP; this mirror preserves the structural changes and score mapping.
-- Full reasoning-text bodies for the 21 UPDATE rows and the two rubric rows live in the applied migration audit log.

-- 1. Rename "Drivers: Effort" -> "Drivers: Content Effort" with content-only rubric (see applied migration for full rubric text)
-- 2. Insert new "Drivers: Presentation" rubric row (see applied migration for full rubric text)
-- 3. Update 4 existing Drivers rows: "1 of 5" -> "1 of 6", notes bumped
-- 4. UPDATE hiring_candidates for 21 candidates: rename signals.effort -> signals.content_effort, add signals.presentation, recompute avg over 13 signals
-- 5. CREATE OR REPLACE resume_drivers() reading content_effort + presentation as sub-signals 5 and 6 (6-signal average, NULL-tolerant for the two new ones)

-- Score mapping (name, content_effort, presentation):
-- Allan Piedrabuena     : 50, 65
-- Katie Barraco         : 80, 55
-- Maximus Moody         : 32, 50
-- Carla Sanders         : 40, 25
-- Jason Villa           : 42, 55
-- Alyssa Sapp           : 82, 80
-- Anthony Papini        : 25, 40
-- Anthony Vela          : 60, 25
-- April Varian          : 40, 60
-- Bob Williams          : 28, 30
-- Cheryl Hemphill       : 58, 40
-- Jakirah Goolsby       : 70, 75
-- Matthew Carlton       : 62, 55
-- Priscilla Brito       : 50, 50
-- Randy Castle          : 25, 25
-- Richard Casias        : 32, 55
-- Vicken Shakarian      : 25, 55
-- Cassandra Alves       : 48, 30
-- John Kostov           : 55, 70
-- Stephanie Rogers      : 45, 35
-- Thomas Lynch          : 62, 55

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
      (hc.resume_analysis->'signals'->'content_effort'->>'score')::numeric       AS content_effort,
      (hc.resume_analysis->'signals'->'presentation'->>'score')::numeric         AS presentation
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
  )
  SELECT round(
    (trajectory_direction + coherent_pursuit + follow_through + goal_orientation
     + COALESCE(content_effort, 0) + COALESCE(presentation, 0))
    / (4.0
       + CASE WHEN content_effort IS NOT NULL THEN 1.0 ELSE 0.0 END
       + CASE WHEN presentation   IS NOT NULL THEN 1.0 ELSE 0.0 END),
    2)
  FROM s
  WHERE trajectory_direction IS NOT NULL
    AND coherent_pursuit    IS NOT NULL
    AND follow_through      IS NOT NULL
    AND goal_orientation    IS NOT NULL;
$function$;
