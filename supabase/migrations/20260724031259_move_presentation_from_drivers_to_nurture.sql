-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-24 03:12:59 UTC (ledger name: move_presentation_from_drivers_to_nurture) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260724031259.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Move "Presentation" from Drivers construct to Nurture construct per Peter directive 2026-07-24.
-- Reasoning: presentation reflects attention-to-detail + pride-in-work-craft, a habit/character trait — fits Nurture (habits built over time)
-- rather than Drivers (motivation directed at this specific role). Content Effort stays in Drivers (it IS role-specific motivation).
-- Framework stays at 13 signals total. Drivers goes back to 5 sub-signals, Nurture goes 4 -> 5.

-- 1. Rename "Drivers: Presentation" -> "Nurture: Presentation" with Nurture-framed description
UPDATE public.hiregauge_rules
SET rule_name = 'Nurture: Presentation',
    short_label = 'Presentation',
    description = 'Quality of the resume as a physical artifact — formatting, layout, readability, absence of typos and errors. Scores the visual/mechanical polish independent of what the content says.

WHAT PRESENTATION SIGNALS (in order of inference strength):
1. Attention to detail on a discretionary deliverable — did they scan their own work before submitting
2. Whether they treat their own outputs as things worth polishing (pride in craft)
3. Weak work-ethic proxy — sustained care on small tasks correlates loosely with sustained care on hard work

CONFOUNDERS (noise sources):
- Technical proficiency: someone unfamiliar with Word/Docs produces messy formatting — skill gap not character signal
- Platform auto-download: Indeed/LinkedIn "download as PDF" produces skeleton artifacts (Bachelor''s degree with blank institution, "Less than 1 year" auto-tags) — some candidates just don''t know to clean these up
- Extraction/OCR artifacts: PDF parsing failures look like candidate errors but are technical issues on our side

INDICATORS OF HIGH PRESENTATION (score 70-100):
- Length appropriate to role and career stage
- Consistent formatting, clean section headers, readable spacing
- No typos, no grammatical errors, no timeline math contradictions
- Custom formatting vs. default template output (evidence of actually building the artifact vs. auto-generating it)
- No Indeed/LinkedIn skeleton artifacts

INDICATORS OF LOW PRESENTATION (score 0-40):
- Multiple typos or grammatical errors ("I delivery Amazon packages", "FOH amd drive thru")
- Broken formatting: ALL CAPS bullets throughout, columns colliding, contact info sandwiched mid-page
- Indeed download artifacts left in place ("Indeed Resume — Page 1" header, "Less than 1 year" auto-tag on every skill, blank template fields showing)
- Timeline math errors
- Duplicate entries (same certification listed twice)

MIDDLE (score 40-70):
- Basic template-clean, no typos, but no custom polish either
- Minor formatting inconsistencies or one typo
- Some template skeleton visible but mostly filled in properly

WHY THIS IS A NURTURE SIGNAL (not Drivers): Nurture captures habits and traits built over time — hard work ethic, personal responsibility, honesty as durable character. Presentation quality is another expression of the same trait cluster: someone who habitually reviews and polishes their own outputs. Drivers captures motivation directed at THIS specific role (content tailoring is Drivers because it reflects investment in this opportunity); presentation is a general habit that shows up in whatever the candidate produces, not a role-specific effort.

CAVEAT ON WEIGHTING: Presentation is one artifact — sample size of one for character inference. Should not be heavily weighted alone. Meaningful mainly in aggregate with other Nurture signals or when extreme (many typos = signal; one typo = noise).

Parser weight: 1 of 5 sub-signals averaged for Nurture.',
    notes = 'Sub-signal 5 of 5 in Nurture construct. Moved from Drivers to Nurture 2026-07-24 per Peter directive: presentation reflects attention-to-detail + craft-pride habits (Nurture territory), not role-specific motivation (Drivers). Distinct from Content Effort which stays in Drivers.',
    updated_at = NOW()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND rule_type='resume_score_rubric'
  AND rule_name='Drivers: Presentation';

-- 2. Revert 4 Drivers sub-signal rows: "1 of 6" -> "1 of 5"
UPDATE public.hiregauge_rules
SET description = REPLACE(description, '1 of 6 sub-signals averaged for Drivers', '1 of 5 sub-signals averaged for Drivers'),
    updated_at  = NOW()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND rule_type='resume_score_rubric'
  AND rule_name IN ('Drivers: Trajectory Direction','Drivers: Coherent Pursuit','Drivers: Follow-Through','Drivers: Goal Orientation');

UPDATE public.hiregauge_rules SET notes='Sub-signal 1 of 5 in Drivers construct.', updated_at=NOW()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_type='resume_score_rubric' AND rule_name='Drivers: Trajectory Direction';
UPDATE public.hiregauge_rules SET notes='Sub-signal 2 of 5 in Drivers construct.', updated_at=NOW()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_type='resume_score_rubric' AND rule_name='Drivers: Coherent Pursuit';
UPDATE public.hiregauge_rules SET notes='Sub-signal 3 of 5 in Drivers construct.', updated_at=NOW()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_type='resume_score_rubric' AND rule_name='Drivers: Follow-Through';
UPDATE public.hiregauge_rules SET notes='Sub-signal 4 of 5 in Drivers construct.', updated_at=NOW()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_type='resume_score_rubric' AND rule_name='Drivers: Goal Orientation';

-- 3. Update Content Effort row: "1 of 6" -> "1 of 5", note "5 of 6" -> "5 of 5"
UPDATE public.hiregauge_rules
SET description = REPLACE(description, '1 of 6 sub-signals averaged for Drivers', '1 of 5 sub-signals averaged for Drivers'),
    notes = 'Sub-signal 5 of 5 in Drivers construct. Distinct from Presentation (which now lives in Nurture as of 2026-07-24). Content Effort stays in Drivers because it captures role-specific motivation (investment in THIS application).',
    updated_at = NOW()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND rule_type='resume_score_rubric'
  AND rule_name='Drivers: Content Effort';

-- 4. Update 4 existing Nurture sub-signal rows: "1 of 4" -> "1 of 5"
UPDATE public.hiregauge_rules
SET description = REPLACE(description, '1 of 4 sub-signals averaged for Nurture', '1 of 5 sub-signals averaged for Nurture'),
    updated_at = NOW()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND rule_type='resume_score_rubric'
  AND rule_name IN ('Nurture: Honesty','Nurture: Concern for Others','Nurture: Hard Work Ethic','Nurture: Personal Responsibility');

UPDATE public.hiregauge_rules SET notes='Sub-signal 1 of 5 in Nurture construct.', updated_at=NOW()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_type='resume_score_rubric' AND rule_name='Nurture: Honesty';
UPDATE public.hiregauge_rules SET notes='Sub-signal 2 of 5 in Nurture construct.', updated_at=NOW()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_type='resume_score_rubric' AND rule_name='Nurture: Concern for Others';
UPDATE public.hiregauge_rules SET notes='Sub-signal 3 of 5 in Nurture construct.', updated_at=NOW()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_type='resume_score_rubric' AND rule_name='Nurture: Hard Work Ethic';
UPDATE public.hiregauge_rules SET notes='Sub-signal 4 of 5 in Nurture construct.', updated_at=NOW()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND rule_type='resume_score_rubric' AND rule_name='Nurture: Personal Responsibility';

-- 5. resume_drivers: revert to 5 sub-signals (remove presentation, keep content_effort)
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

-- 6. resume_nurture: add presentation as 5th sub-signal, backward-compatible (existing 4 signals still required, presentation optional)
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
  WHERE honesty IS NOT NULL
    AND concern_for_others      IS NOT NULL
    AND hard_work_ethic         IS NOT NULL
    AND personal_responsibility IS NOT NULL;
$function$;
