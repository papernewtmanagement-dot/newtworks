-- Migration: interview_score_rubric
-- Adds iv_* aggregate columns to hiring_candidates, extends hiregauge_rules rule_type CHECK
-- to allow interview_score_rubric, and seeds 8 interview_score_rubric config rules.
-- Sibling migration 20260720230030_v_hiring_candidates_rebuild_with_iv_composite.sql
-- rebuilds v_hiring_candidates to expose iv_composite.

-- Part A: iv_* columns on hiring_candidates
ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS iv_nature NUMERIC,
  ADD COLUMN IF NOT EXISTS iv_nurture NUMERIC,
  ADD COLUMN IF NOT EXISTS iv_drivers NUMERIC,
  ADD COLUMN IF NOT EXISTS iv_verdict TEXT,
  ADD COLUMN IF NOT EXISTS iv_verdict_reason TEXT,
  ADD COLUMN IF NOT EXISTS iv_scored_at TIMESTAMPTZ;

ALTER TABLE public.hiring_candidates
  DROP CONSTRAINT IF EXISTS hiring_candidates_iv_verdict_check;
ALTER TABLE public.hiring_candidates
  ADD CONSTRAINT hiring_candidates_iv_verdict_check
  CHECK (iv_verdict IS NULL OR iv_verdict = ANY (ARRAY['hire','consider','lean_decline','decline']));

COMMENT ON COLUMN public.hiring_candidates.iv_nature IS 'Interview-layer nature construct score 0-100 (role fit + trait confirmation). Mean of nature-tagged probe scores × 10.';
COMMENT ON COLUMN public.hiring_candidates.iv_nurture IS 'Interview-layer nurture construct score 0-100 (character floor + honesty). Mean of nurture-tagged probe scores × 10.';
COMMENT ON COLUMN public.hiring_candidates.iv_drivers IS 'Interview-layer drivers construct score 0-100 (motivation + engagement). Mean of drivers-tagged probe scores × 10.';
COMMENT ON COLUMN public.hiring_candidates.iv_verdict IS 'Interview-layer verdict from grading: hire | consider | lean_decline | decline. Not final_decision — this is interview-layer signal only.';
COMMENT ON COLUMN public.hiring_candidates.iv_verdict_reason IS 'Interview verdict reason: character_floor | structural_mismatch | culture_fit | direction_uncertainty | (blank for hire/consider).';
COMMENT ON COLUMN public.hiring_candidates.iv_scored_at IS 'Timestamp when iv_* scores + verdict were computed and persisted.';

-- Part B: Extend hiregauge_rules rule_type CHECK
ALTER TABLE public.hiregauge_rules
  DROP CONSTRAINT IF EXISTS hiregauge_rules_rule_type_check;
ALTER TABLE public.hiregauge_rules
  ADD CONSTRAINT hiregauge_rules_rule_type_check
  CHECK (rule_type = ANY (ARRAY['archetype','coaching_variant','money_motivator','diagnostic_tool','filter_rule','exit_mode','recommendation_logic','framework_principle','behavioral_tell','reader_vulnerability','strategic_seat_pattern','character_floor','validity_rule','drive_test','resume_screen_signal','resume_score_rubric','interview_score_rubric']));

-- Part C: Seed 8 interview_score_rubric config rules
INSERT INTO public.hiregauge_rules (agency_id, rule_type, rule_name, short_label, description, notes, calibration_status, n_count, real_world_validated, is_active)
VALUES
('126794dd-25ff-47d2-a436-724499733365', 'interview_score_rubric', 'Config: Composite math + weights + verdict thresholds', 'Composite Config',
$$Interview-layer composite math. Weights Nature 0.1429 / Nurture 0.4286 / Drivers 0.4286 (per hiregauge_layer_composite_weights layer=interview). Scale 0-100.

Verdict bands (composite score, absent floor/overlay):
- 75-100: HIRE
- 60-75: CONSIDER
- 45-60: LEAN_DECLINE (needs explicit strengths in strengths list to hire-override)
- <45: DECLINE

Hard-floor overrides (bypass composite entirely):
- Any character_floor probe RED (1-3/10 raw) = automatic DECLINE, reason=character_floor
- Character_floor probe YELLOW (4-6/10) + confirming CTS trait below Story threshold = DECLINE, reason=structural_mismatch
- Framework archetype match to non-hire archetype = DECLINE regardless of composite, reason=structural_mismatch

Character judgments happen at nurture layer; role-fit and trait confirmation at nature; motivation and engagement at drivers.$$,
'Config row — parser reads first. Interview layer sits alongside resume + assessment + reference layers in the 4-layer composite.',
'framework_principle', 1, true, true),

('126794dd-25ff-47d2-a436-724499733365', 'interview_score_rubric', 'Probe verdict mapping: Green / Yellow / Red / No Answer', 'Verdict Bands',
$$Each interview probe scores 1-10 based on the interviewer's diagnostic read of the answer:

- GREEN (7-9/10): Answer shows the listen_for signal clearly. Concrete evidence, specific instance, honest self-awareness. No hedge.
- YELLOW (4-6/10): Partial signal. Hedged, vague, mixed, semi-specific, or answer present but doesn't fully confirm or overturn the concern.
- RED (1-3/10): Answer matches the concern. Evasive, generic, rehearsed, or actively problematic. On character_floor probes, this triggers automatic decline.
- NO ANSWER: Excluded from construct average. If >30% of probes are NO ANSWER, composite marked provisional. If >50%, don't compute; request follow-up.

Verdict pill color follows the same tri-band scheme.$$,
'Applies to every probe regardless of source.',
'framework_principle', 1, true, true),

('126794dd-25ff-47d2-a436-724499733365', 'interview_score_rubric', 'Score the diagnostic observation, not the linguistic texture', 'Diagnostic vs Texture',
$$Interview notes are interpretive summaries by design. The interviewer already read the linguistic texture of the answer (hedges, tone, specificity) and compressed it into a summary phrase.

Score the SIGNAL the interviewer surfaced — not the words they used to describe it.

Example: interviewer note "she rambled and gave semi-vague examples". The signal is "communication is broadcast-heavy, not tightly organized." Score that signal (probably YELLOW on the specific probe). Do NOT re-parse the summary for additional linguistic tells ("rambled" as a word is not itself a red flag).

This rule prevents double-counting the interviewer's read and prevents Claude from over-weighting linguistic cues in the summary that were already accounted for by the interviewer.$$,
'Calibrated 2026-07-20 via Priscilla Brito interview scoring — first pass over-parsed summary phrases; Peter corrected.',
'framework_principle', 1, true, true),

('126794dd-25ff-47d2-a436-724499733365', 'interview_score_rubric', 'Probe source to construct mapping', 'Construct Mapping',
$$Each probe feeds one construct (nature | nurture | drivers). Mapping keyed off probe.source prefix in custom_probes JSONB:

- warmup:*  --> drivers (why_insurance, why_agency, frogs/personal, candidate_questions)
- resume:*  (role-fit signals like biggest-account, sf-experience-stale, scaffolded-career)  --> nature
- resume:*  (honesty signals like agent-title-floating, gap-explanation)  --> nurture
- character_floor:*  --> nurture  (Honesty, ConcernForOthers, HardWorkEthic, PersonalResponsibility)
- manual:*  --> nature  (Suggs-pool trait triggers — confirms or overturns CTS trait read)
- validity:*  --> nurture  (self-awareness of validity flag reads as consistency signal)
- framework:archetype:*  --> nature  (archetype confirmation)
- motivation:money_motivator  --> drivers
- structure:*  --> nature  (structural-fit pattern confirmation)

Default fallback for unknown prefixes: nature.$$,
'Extend when new probe source prefixes appear. Nature and drivers are role-fit and motivation; nurture is character and honesty.',
'framework_principle', 1, true, true),

('126794dd-25ff-47d2-a436-724499733365', 'interview_score_rubric', 'Construct rollup math', 'Construct Rollup',
$$Nature = mean(all nature-tagged probe scores, excluding NO ANSWER) × 10
Nurture = mean(all nurture-tagged probe scores, excluding NO ANSWER) × 10
Drivers = mean(all drivers-tagged probe scores, excluding NO ANSWER) × 10
Composite = 0.1429 × Nature + 0.4286 × Nurture + 0.4286 × Drivers
Rounded to 1 decimal for display, stored numeric.

NO ANSWER probes: excluded from mean, but count against provisional-flag threshold (>30% no-answer → provisional).$$,
'Weights from hiregauge_layer_composite_weights layer=interview. Change weights there, not here.',
'framework_principle', 1, true, true),

('126794dd-25ff-47d2-a436-724499733365', 'interview_score_rubric', 'Hard floor: any character_floor probe RED = automatic DECLINE', 'Char Floor Override',
$$Any character_floor probe scored RED (1-3/10) triggers automatic DECLINE, verdict_reason = character_floor.

This bypasses the composite score entirely. Composite of 90 with a RED honesty probe is still a decline. Core Principle #550 (Recruiting): character floor 7/10 non-negotiable, no exceptions, no overrides.

The four character floors:
- Honesty (fi_honesty proxy)
- Concern for Others (fi_concern_for_others proxy)
- Hard Work Ethic (fi_hard_work_ethic proxy)
- Personal Responsibility (fi_personally_responsible proxy)

Distinct from structural_mismatch: RED on character_floor = ethics or character concern (never hire anywhere). Structural_mismatch = shape does not fit this seat (could work elsewhere in different structure).$$,
'Absolute rule. No override path.',
'framework_principle', 1, true, true),

('126794dd-25ff-47d2-a436-724499733365', 'interview_score_rubric', 'Character floor YELLOW + confirming CTS trait = structural_mismatch decline', 'Structural Mismatch Overlay',
$$Character_floor probe YELLOW (4-6/10) alone = concern requiring reference check to clear. Not automatic decline.

BUT: Character_floor probe YELLOW + confirming CTS trait score below Story-agency threshold for that trait = STRUCTURAL_MISMATCH decline. The convergence of interview signal + assessment signal on the same trait deficit means the shape does not fit any listener-first seat this agency operates.

Example (calibrated on Priscilla Brito 2026-07-20):
- character_floor:ConcernForOthers = YELLOW 5/10 (weak listening, self-focused rambling; interviewer read: "relatable, not cold")
- CTS Compassion = 21 (well below Story threshold; empathy composite ~30)
- Combined = structural_mismatch: broadcast-communicator into listener-first seat. Not a moral concern (not RED), a fit concern.

Verdict = DECLINE, verdict_reason = structural_mismatch, not character_floor. Candidate could fit warm-inbound-with-manager-feed seat elsewhere; not fit for Story seats today.$$,
'First calibration: Priscilla Brito 2026-07-20. Watch for n=2 reproduction.',
'emerging_n1', 1, true, true),

('126794dd-25ff-47d2-a436-724499733365', 'interview_score_rubric', 'Provisional confidence — missing-answer thresholds', 'Provisional Flags',
$$Missing-answer thresholds against total probes offered (excluding warmups from count):

- >30% NO ANSWER  --> composite marked provisional (surface warning at UI header, verdict still computed).
- >50% NO ANSWER  --> do not compute composite; return "insufficient data, follow-up interview required".

Missing answers dilute confidence but do not reduce score — the honest signal is: "we do not know enough yet". Score what you have, flag the confidence.$$,
'', 'framework_principle', 1, true, true);
