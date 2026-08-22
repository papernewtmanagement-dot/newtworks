-- Reference layer scoring — fills the three construct feeders that have been
-- deliberate NULL stubs since the three-construct build.
--
-- WHY NOW: reference emails became structured data on 2026-08-19 (intake mode
-- "references" -> hiring_candidate_references). Before that there was nothing to
-- score, which is why the stubs were stubs. Peter approved the design 2026-08-22.
--
-- EVIDENCE BASE (verified against source, not recalled):
--   * Unstructured reference checks predict job performance at about .26
--     (Hunter & Hunter 1984, table 9). Weak on its own.
--   * STRUCTURE is the moderator. Taylor, Pajo, Cheung & Stringfield 2004,
--     Personnel Psychology 57(3) 745-772: a structured telephone reference check
--     over 223 applicants predicted supervisory performance ratings at r = .25
--     uncorrected, .36 corrected for range restriction and criterion
--     unreliability — the band of a personality inventory. Their three
--     dimensions were conscientiousness, agreeableness and customer focus, for
--     entry-level customer-contact jobs: this agency's roles.
--   * Reference checks were among the predictors the Sackett et al. re-analysis
--     of the 1998 estimates could NOT recompute, because the underlying studies
--     did not report enough. Treat .26 as soft rather than settled.
--   * Equal weights over estimated weights absent a large local validation
--     sample (Wainer 1976) — the standing house rule.
--
-- WHY THE SIGNAL SET NEEDS NO INVENTING: Marie's reference script already asks,
-- by name, for the four Character dimensions in core_principles #550 (Honesty,
-- Concern for Others, Hard Work Ethic, Personal Responsibility) and for Attitude
-- and Motivation, which the recruiting principle states ARE the Commitment
-- construct. Each signal below is anchored to lines the referee actually
-- answered. Nothing is scored that the script does not ask.
--
-- CANDOR IS A FLAG, NOT A SCORE. Referees are chosen by the candidate, so
-- reference write-ups run lenient; the live examples include two "no complaints"
-- answers and a development note of "he's just young". A referee who names a
-- real weakness gives a more usable read than one who says everything is great —
-- but that is a property of the REFEREE, not a virtue of the candidate, so it
-- must never be averaged into a construct. Same treatment response speed got in
-- the assessment: recorded, displayed, never blocking. Deliberately excluded
-- from every construct function below.
--
-- SCORED BY CLAUDE IN CHAT, never Groq, never the grunt — matching the screen
-- layer precedent (20260813183103). Construct scores are NEVER stored; they are
-- computed on read, per the compensation-data-freshness doctrine applied to
-- hiring scores.

BEGIN;

-- 1 ---------------------------------------------------------------------
ALTER TABLE public.hiring_candidate_references
  ADD COLUMN IF NOT EXISTS reference_analysis jsonb;

COMMENT ON COLUMN public.hiring_candidate_references.reference_analysis IS
'Per-reference scoring. Shape: {signals: {honesty, concern_for_others,
work_ethic, personal_responsibility, attitude_toward_work, motivation,
rehire_intent, learning_speed, communication, demonstrated_sales_ability}
0-100 ints; candor 0-100 int (FLAG — displayed, never averaged into a
construct); referee text; relationship text; narrative text; scored_at;
scored_model}. Scored from body_text. Derived construct scores are NEVER
stored — computed on read by reference_capability / reference_character /
reference_commitment / verdict_reference.';

-- 2 ---------------------------------------------------------------------
ALTER TABLE public.hiregauge_rules
  DROP CONSTRAINT hiregauge_rules_rule_type_check;

ALTER TABLE public.hiregauge_rules
  ADD CONSTRAINT hiregauge_rules_rule_type_check
  CHECK ((rule_type = ANY (ARRAY[
    'archetype'::text, 'coaching_variant'::text, 'money_motivator'::text,
    'diagnostic_tool'::text, 'filter_rule'::text, 'exit_mode'::text,
    'recommendation_logic'::text, 'framework_principle'::text,
    'behavioral_tell'::text, 'reader_vulnerability'::text,
    'strategic_seat_pattern'::text, 'character_floor'::text,
    'validity_rule'::text, 'drive_test'::text, 'resume_screen_signal'::text,
    'resume_score_rubric'::text, 'interview_score_rubric'::text,
    'screen_score_rubric'::text, 'reference_score_rubric'::text
  ])));

-- 3 ---------------------------------------------------------------------
INSERT INTO public.hiregauge_rules
  (rule_type, rule_name, short_label, description, notes, calibration_status, verdict_impact, is_active)
VALUES
('reference_score_rubric','honesty','Honesty (Character)',
 'Script line "Honesty". Character construct, dimension 1 of core_principles #550. 0-100.',
 'HIGH (75-100): referee volunteers that honesty is tested and held, or names a moment the candidate told an inconvenient truth. MID (40-74): affirmed without incident or example ("no issues"). LOW (0-39): hedging, a named incident, or a referee who declines to answer this line while answering others. A skipped honesty line in an otherwise complete write-up is itself the signal.',
 'proposed','informational',true),

('reference_score_rubric','concern_for_others','Concern for Others (Character)',
 'Script line "Concern for others", supported by "What did you appreciate the most". Character construct, dimension 2 of core_principles #550. 0-100.',
 'HIGH (75-100): named behavior toward specific people — covered a shift, trained someone, defused a customer. MID (40-74): general likability ("everyone likes him", "gets along well"). LOW (0-39): friction with teammates or customers named.',
 'proposed','informational',true),

('reference_score_rubric','work_ethic','Hard Work Ethic (Character)',
 'Script lines "Work ethic" AND "Attendance and punctuality" read together. Character construct, dimension 3 of core_principles #550. 0-100.',
 'HIGH (75-100): both lines strong, with evidence — picked up extra work, took the unglamorous jobs, attendance never a question. MID (40-74): one line strong and the other bare. LOW (0-39): attendance problems, or effort described as needing supervision.',
 'proposed','informational',true),

('reference_score_rubric','personal_responsibility','Personal Responsibility (Character)',
 'Script line "Personal responsibility", supported by "When they disagreed, how did they respond". Character construct, dimension 4 of core_principles #550. 0-100.',
 'HIGH (75-100): owns outcomes, raises problems early, disagreement handled directly and respectfully. MID (40-74): affirmed by reference to another line ("same as above") with no independent evidence. LOW (0-39): deflection, or disagreement handled by going quiet or going around.',
 'proposed','informational',true),

('reference_score_rubric','attitude_toward_work','Attitude Toward the Work (Commitment)',
 'Script lines "Attitude towards sales", "What did they really not like to do", "What about them drove you crazy". Commitment construct — Attitude, dimension 2 of the Five-Dimension Matching Profile. 0-100.',
 'HIGH (75-100): positive toward selling specifically, and the dislike/annoyance lines produce either nothing real or something trivial. MID (40-74): willing but neutral about selling. LOW (0-39): avoids selling, or the dislike lines surface a pattern that would matter in this seat.',
 'proposed','informational',true),

('reference_score_rubric','motivation','Motivation (Commitment)',
 'Script lines "Source of motivation" AND "Ambition and drive". Commitment construct — Motivation, dimension 3 of the Five-Dimension Matching Profile. 0-100.',
 'HIGH (75-100): self-starting, with evidence of drive that cost the candidate something. MID (40-74): motivated while supervised, or motivation described only in terms of money. LOW (0-39): needs pushing, or no motivation the referee can name. Score the TYPE and LEVEL the referee describes — never reduce to one "primary" motivator (core_principles #550).',
 'proposed','informational',true),

('reference_score_rubric','rehire_intent','Rehire Intent (Commitment)',
 'Script line "Would you look forward to working with them again". Commitment construct. 0-100. The single most-used item in reference-check practice; scored on its own because a qualified yes and an emphatic yes are different data.',
 'HIGH (75-100): unqualified yes with a reason attached. MID (40-74): bare yes, no reason. LOW (0-39): qualified yes, evasion, or no. Read alongside "Why did they leave" — a warm rehire answer against a departure the referee will not explain is a contradiction worth flagging in the narrative.',
 'proposed','informational',true),

('reference_score_rubric','learning_speed','Learning Speed (Capability)',
 'Script lines "Learning style" AND "In what areas did they need the most development". Capability construct. 0-100.',
 'HIGH (75-100): moved up, picked up new roles, learned without hand-holding. MID (40-74): learns adequately with training. LOW (0-39): development areas named that go to trainability itself. Capability carries only 9% of this layer — a referee is a weak judge of ability and the weighting already says so.',
 'proposed','informational',true),

('reference_score_rubric','communication','Communication (Capability)',
 'Script line "Communication style", supported by "What were they really good at". Capability construct. 0-100.',
 'HIGH (75-100): specific strength named — listening, explaining, handling an upset customer. MID (40-74): "great communicator" with nothing behind it. LOW (0-39): communication named as a development area.',
 'proposed','informational',true),

('reference_score_rubric','demonstrated_sales_ability','Demonstrated Sales Ability (Capability)',
 'Script line "Sales ability". Capability construct. 0-100. NULL, not zero, when the referee had no way to observe selling — a warehouse supervisor cannot rate this and must not be scored as if the answer were poor.',
 'HIGH (75-100): observed selling with a result attached — upsell numbers, bonuses earned, customers asking for them. MID (40-74): believed capable, not observed. LOW (0-39): observed and weak.',
 'proposed','informational',true),

('reference_score_rubric','candor','Candor (FLAG — never averaged)',
 'Not a candidate score. Rates how much usable information THIS REFEREE gave. 0-100. Never enters any construct function; displayed alongside the reference so a glowing write-up from an uncritical referee is read for what it is.',
 'HIGH (75-100): names a real development area, a real irritation, and a concrete reason for leaving. MID (40-74): one soft criticism, the rest uniformly positive. LOW (0-39): "no complaints" throughout, development area is an unavoidable fact like age or tenure, nothing checkable. Candidate-selected referees run lenient by construction — low candor lowers confidence in the reference, it does not lower the candidate.',
 'proposed','informational',true),

('reference_score_rubric','reference_layer_config','Config: Reference layer scoring',
 'Construct scores are computed on read: each reference gets the unit-weighted mean of its own non-null signals for that construct, then references are averaged with EQUAL WEIGHT so one referee is one vote regardless of how many lines they answered. Layer composite mixes the constructs 0.0909 capability / 0.5455 character / 0.3636 commitment per hiregauge_layer_composite_weights — references are a character read, and the weighting says so. Verdict at 75 pass / 60 consider per hiregauge_verdict_thresholds.',
 'TWO-REFERENCE MINIMUM: every construct function returns NULL until at least two scored references exist, so the layer contributes nothing to the overall verdict on the strength of one referee. A single reference is noise; the same discipline as never coaching off a scorecard step measured fewer than three days. The per-reference numbers still display — the gate is on the layer counting, not on Peter seeing it. Basis: Hunter & Hunter 1984 table 9 (unstructured reference checks about .26); Taylor, Pajo, Cheung & Stringfield 2004 Personnel Psychology 57(3) 745-772 (structured procedure, 223 applicants, r = .25 uncorrected / .36 corrected — structure is the moderator); reference checks were among the predictors the Sackett et al. re-analysis could not recompute for want of reported data, so .26 is soft not settled; Wainer 1976 (equal weights beat estimated weights absent a large local sample). Scored by Claude in chat only.',
 'proposed','informational',true);

-- 4 ---------------------------------------------------------------------
-- Shared aggregator. One referee, one vote.
CREATE OR REPLACE FUNCTION public._reference_construct(p_candidate_id uuid, p_signals text[])
RETURNS numeric
LANGUAGE sql
STABLE
AS $function$
  WITH per_ref AS (
    SELECT r.id, avg(v.val) AS ref_score
    FROM public.hiring_candidate_references r
    CROSS JOIN LATERAL (
      SELECT (r.reference_analysis -> 'signals' ->> s)::numeric AS val
      FROM unnest(p_signals) AS s
    ) v
    WHERE r.candidate_id = p_candidate_id
      AND r.reference_analysis IS NOT NULL
      AND v.val IS NOT NULL
    GROUP BY r.id
  )
  SELECT CASE WHEN count(*) >= 2 THEN round(avg(ref_score), 2) ELSE NULL END
  FROM per_ref;
$function$;

COMMENT ON FUNCTION public._reference_construct(uuid, text[]) IS
'Mean of the per-reference means for the given signal names. Each reference is averaged over its own non-null signals first, so a referee who answered more lines does not outvote one who answered fewer. Returns NULL below two scored references — see hiregauge_rules reference_layer_config.';

CREATE OR REPLACE FUNCTION public.reference_capability(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE
AS $function$
  SELECT public._reference_construct(p_candidate_id,
    ARRAY['learning_speed','communication','demonstrated_sales_ability']);
$function$;

CREATE OR REPLACE FUNCTION public.reference_character(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE
AS $function$
  SELECT public._reference_construct(p_candidate_id,
    ARRAY['honesty','concern_for_others','work_ethic','personal_responsibility']);
$function$;

CREATE OR REPLACE FUNCTION public.reference_commitment(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE
AS $function$
  SELECT public._reference_construct(p_candidate_id,
    ARRAY['attitude_toward_work','motivation','rehire_intent']);
$function$;

-- 5 ---------------------------------------------------------------------
-- Threshold note still carried the pre-2026-08-04 construct names. Values
-- unchanged; wording brought onto Peter's current terms.
UPDATE public.hiregauge_verdict_thresholds
SET notes = 'Reference layer — weighted mix of capability/character/commitment scored from the reference write-ups. 75+ pass, 60-74 consider, <60 decline.'
WHERE layer = 'reference';

COMMIT;
