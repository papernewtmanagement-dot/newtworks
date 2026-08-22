-- Resume "Effort" signal — 12th signal overall, 5th Drivers sub-signal.
-- Scores the resume as ARTIFACT (level of care in production) not the content signals inside it.
-- Closes a framework gap Peter flagged 2026-07-23: existing 11 signals score what the resume SAYS, not how much care went into producing it.

-- 1. Insert new resume_score_rubric row
INSERT INTO public.hiregauge_rules (
  agency_id, rule_type, rule_name, short_label,
  hiring_stage, description, notes,
  calibration_status, real_world_validated, is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'resume_score_rubric',
  'Drivers: Effort',
  'Effort',
  ARRAY['resume_review'],
  'Level of care and effort invested in producing the resume artifact itself. Scores the resume as artifact, not the content signals within it.

INDICATORS OF HIGH EFFORT (score 70-100):
- Length appropriate to role and career stage (not one page for 15-year career; not 4 pages for entry-level)
- Role-specific tailoring: industry terminology, company or program names, targeted skills for the posted position
- Specific and quantified claims (30% efficiency gain, 22-month tenure, $1.2M portfolio) vs generic buzzwords
- Real institution and system names that can be verified (MOD, SF Billing, TASP designation, specific employer names)
- Consistent formatting, readable structure, no typos, no timeline math errors
- Thoughtful tone, not template boilerplate

INDICATORS OF LOW EFFORT (score 0-40):
- Very short for career stage (one-page resume claiming 10+ years experience with only bullet titles)
- Generic template with zero role-tailoring — no industry terms, no company names, no program awareness
- Mass-application boilerplate (identical objective statement pattern, no adaptation)
- Typos, inconsistent formatting, timeline math errors (dates that do not add up)
- Buzzword-only skills grid with no verifiable outcomes ("Team Building, Client Coordination, Professional Communication")
- Tone reads as spray-and-pray

MIDDLE (score 40-70):
- Length roughly appropriate, some specifics but generic gaps
- Partial role-tailoring — mentions industry once, otherwise generic
- Mix of specific claims and buzzwords
- Minor formatting inconsistencies or one or two typos

WHY THIS MATTERS: Effort on the resume artifact is a proxy for role-specific motivation. A candidate who tailors their resume for THIS role signals genuine interest. A candidate spraying identical resumes across postings signals lower drive. Distinct from content signals — a candidate can have strong career facts (drivers, nurture, nature all high) but produce a boilerplate resume, and that boilerplate itself is a drive signal.

Parser weight: 1 of 5 sub-signals averaged for Drivers.',
  'Sub-signal 5 of 5 in Drivers construct. Distinct from Follow-Through (which measures completion rate across career): Effort scores the specific application artifact as a proxy for role-specific motivation on THIS opportunity. Added 2026-07-23 to close a gap Peter flagged: existing 11 signals score what the resume SAYS, not how much care went into producing it.',
  'proposed',
  false,
  true
);

-- 2. Update 4 existing Drivers sub-signals: description "1 of 4" -> "1 of 5", notes fix per-row
UPDATE public.hiregauge_rules
SET description = REPLACE(description, '1 of 4 sub-signals averaged for Drivers', '1 of 5 sub-signals averaged for Drivers'),
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

-- 3. resume_drivers cell fn: include effort as 5th sub-signal, backward-compatible.
-- Preserves the "all 4 original signals required" strict guard; effort is optional additive.
-- Existing 69 candidates with effort=NULL: divide by 4 (byte-identical to previous output).
-- New candidates with effort scored: divide by 5.
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
      (hc.resume_analysis->'signals'->'effort'->>'score')::numeric               AS effort
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
  )
  SELECT round(
    (trajectory_direction + coherent_pursuit + follow_through + goal_orientation + COALESCE(effort, 0))
    / (4.0 + CASE WHEN effort IS NOT NULL THEN 1.0 ELSE 0.0 END),
    2)
  FROM s
  WHERE trajectory_direction IS NOT NULL
    AND coherent_pursuit    IS NOT NULL
    AND follow_through      IS NOT NULL
    AND goal_orientation    IS NOT NULL;
$function$;
