-- screen_layer_step1_plumbing
-- Adds hiring_candidates.screen_analysis, hiregauge_layer_composite_weights
-- 'screen' rows, hiregauge_verdict_thresholds 'screen' row,
-- hiregauge_rules screen_score_rubric rows, and the screen_character /
-- screen_commitment / verdict_screen functions.

BEGIN;

-- 2.1 ------------------------------------------------------------------
ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS screen_analysis jsonb;

COMMENT ON COLUMN public.hiring_candidates.screen_analysis IS
'Screen layer (stint 5 free-text) scoring. Shape: {signals:
{job_history_candor, accountability, role_interest_specificity,
challenge_realism} 0-100 ints, narrative text, scored_at, scored_model}.
Derived construct scores are NEVER stored — computed on read by
screen_character / screen_commitment / verdict_screen. Scored by
Claude in chat only.';

-- 2.2a ------------------------------------------------------------------
ALTER TABLE public.hiregauge_layer_composite_weights
  DROP CONSTRAINT hiregauge_layer_composite_weights_layer_check;

ALTER TABLE public.hiregauge_layer_composite_weights
  ADD CONSTRAINT hiregauge_layer_composite_weights_layer_check
  CHECK ((layer = ANY (ARRAY['resume'::text, 'assessment'::text, 'interview'::text, 'reference'::text, 'screen'::text])));

-- 2.2b ------------------------------------------------------------------
INSERT INTO public.hiregauge_layer_composite_weights (layer, construct, weight)
VALUES
  ('screen', 'character',  0.5000),
  ('screen', 'commitment', 0.5000);

-- 2.3 ------------------------------------------------------------------
INSERT INTO public.hiregauge_verdict_thresholds (layer, pass_threshold, consider_threshold, notes)
VALUES (
  'screen',
  70,
  50,
  'Screen layer — 5th scored layer (stint-5 free-text). Same soft bar as resume (structurally the closest analog: sparse per-field signal, not a full instrument). 70+ pass, 50-69 consider, <50 decline.'
);

-- 2.4a ------------------------------------------------------------------
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
    'screen_score_rubric'::text
  ])));

-- 2.4b ------------------------------------------------------------------
INSERT INTO public.hiregauge_rules
  (rule_type, rule_name, short_label, description, notes, calibration_status, verdict_impact, is_active)
VALUES
(
  'screen_score_rubric',
  'job_history_candor',
  'Job History Candor (Character)',
  'Scores stint-5 item 1 (reasons for leaving each job). Character construct. 0-100. Substance only — writing quality is never scored anywhere in this layer.',
  'HIGH (75-100): every move explained; employers/dates consistent with the resume; ownership language where a move went badly. MID (40-74): plausible but thin; one gap glossed over. LOW (0-39): blame-only narrative, contradicts the resume, gaps papered over. Cross-check against resume_extracted_text when scoring.',
  'proposed',
  'informational',
  true
),
(
  'screen_score_rubric',
  'accountability',
  'Accountability (Character)',
  'Scores stint-5 item 5 (a time something went wrong because of your decision). Character construct. 0-100. This is the written Personal Responsibility probe.',
  'HIGH (75-100): real consequential mistake named, concrete correction taken, genuine "here is what I would do differently." MID (40-74): minor mistake, generic correction. LOW (0-39): humble-brag disguised as a mistake, blames others, no correction offered.',
  'proposed',
  'informational',
  true
),
(
  'screen_score_rubric',
  'role_interest_specificity',
  'Role Interest Specificity (Commitment)',
  'Scores stint-5 item 2 (what caused your interest in this job). Commitment construct (attitude toward the position). 0-100.',
  'HIGH (75-100): specific to insurance / this agency / this kind of work, tied to the candidate''s own history. MID (40-74): sincere but generic industry interest. LOW (0-39): could be pasted into any application ("I love helping people").',
  'proposed',
  'informational',
  true
),
(
  'screen_score_rubric',
  'challenge_realism',
  'Challenge Realism (Commitment)',
  'Scores stint-5 item 3 (greatest challenges of this job). Commitment construct (realistic understanding of the position). 0-100.',
  'HIGH (75-100): names the actual hard parts — rejection, licensing, pace, product learning. MID (40-74): partially realistic. LOW (0-39): softballs ("learning the computer system") or claims of no real challenges.',
  'proposed',
  'informational',
  true
),
(
  'screen_score_rubric',
  'screen_layer_config',
  'Config: Screen layer scoring',
  'Screen = 5th scored layer, replaces the retired email screen''s scoring role. Scored by Claude in chat only (never Groq, never the grunt). character = mean of non-null(job_history_candor, accountability); commitment = mean of non-null(role_interest_specificity, challenge_realism); layer composite = 0.5/0.5 weighted mix per hiregauge_layer_composite_weights. Capability is NEVER scored in this layer (writing quality never scored — standing doctrine); screen_capability deliberately does not exist as a function.',
  'Items 4 (comp structure) and 6 (insurance move) remain FLAGS via answer_key, never numeric scores, never auto-declining. Item 7 (reference name) is never scored; it feeds the Reference layer; refusal or evasion to name a checkable reference → amber assessment_flags entry. Screen never feeds auto_decline_on_assessment_score. Anchors reward verifiable specifics only — polish earns nothing; every specific becomes an interview probe and a reference-check item. Overall verdict influence: 5% (chr 5 + com 10 + cap 0, over equal construct thirds). Basis: Sackett, Zhang, Berry & Lievens 2022 J Appl Psychol 107(11) 2040-2068 (biodata-family items predict; unkeyed versions discounted); Kuncel, Klieger, Connelly & Ones 2013 J Appl Psychol 98(6) 1060-1072 (fixed-rule combination beats holistic); Birkeland et al. 2006 Int J Sel Assess 14 317-335 (inflation concentrates on transparent job-relevant items); Mittelstadt et al. 2024 Sci Rep (LLMs at expert level on judgment items -> weight cap + live re-verification is the defense).',
  'proposed',
  'informational',
  true
);

-- 2.5a ------------------------------------------------------------------
CREATE FUNCTION public.screen_character(p_candidate_id uuid)
RETURNS numeric
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_sig jsonb;
  v_job_history_candor numeric;
  v_accountability numeric;
  v_sum numeric := 0;
  v_n int := 0;
BEGIN
  SELECT screen_analysis -> 'signals' INTO v_sig
  FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF v_sig IS NULL THEN RETURN NULL; END IF;

  v_job_history_candor := (v_sig ->> 'job_history_candor')::numeric;
  v_accountability     := (v_sig ->> 'accountability')::numeric;

  IF v_job_history_candor IS NOT NULL THEN v_sum := v_sum + v_job_history_candor; v_n := v_n + 1; END IF;
  IF v_accountability     IS NOT NULL THEN v_sum := v_sum + v_accountability;     v_n := v_n + 1; END IF;

  IF v_n = 0 THEN RETURN NULL; END IF;
  RETURN round(v_sum / v_n, 2);
END;
$function$;

COMMENT ON FUNCTION public.screen_character(uuid) IS
'Screen layer Character cell. Mean of non-null(job_history_candor,
accountability) from hiring_candidates.screen_analysis->signals. NULL if
screen_analysis is NULL or both signals missing. screen_capability
deliberately does not exist — the Screen layer never scores capability
(writing quality never scored — standing doctrine).';

CREATE FUNCTION public.screen_commitment(p_candidate_id uuid)
RETURNS numeric
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_sig jsonb;
  v_role_interest_specificity numeric;
  v_challenge_realism numeric;
  v_sum numeric := 0;
  v_n int := 0;
BEGIN
  SELECT screen_analysis -> 'signals' INTO v_sig
  FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF v_sig IS NULL THEN RETURN NULL; END IF;

  v_role_interest_specificity := (v_sig ->> 'role_interest_specificity')::numeric;
  v_challenge_realism         := (v_sig ->> 'challenge_realism')::numeric;

  IF v_role_interest_specificity IS NOT NULL THEN v_sum := v_sum + v_role_interest_specificity; v_n := v_n + 1; END IF;
  IF v_challenge_realism         IS NOT NULL THEN v_sum := v_sum + v_challenge_realism;         v_n := v_n + 1; END IF;

  IF v_n = 0 THEN RETURN NULL; END IF;
  RETURN round(v_sum / v_n, 2);
END;
$function$;

COMMENT ON FUNCTION public.screen_commitment(uuid) IS
'Screen layer Commitment cell. Mean of non-null(role_interest_specificity,
challenge_realism) from hiring_candidates.screen_analysis->signals. NULL if
screen_analysis is NULL or both signals missing. screen_capability
deliberately does not exist — the Screen layer never scores capability
(writing quality never scored — standing doctrine).';

GRANT EXECUTE ON FUNCTION public.screen_character(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.screen_commitment(uuid) TO authenticated, service_role;

-- 2.5b ------------------------------------------------------------------
CREATE FUNCTION public.verdict_screen(p_candidate_id uuid)
RETURNS TABLE(capability_score numeric, character_score numeric, commitment_score numeric, composite numeric, verdict text)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_chr numeric; v_com numeric;
  v_w_chr numeric; v_w_com numeric;
  v_wsum numeric := 0; v_sum numeric := 0;
BEGIN
  v_chr := public.screen_character(p_candidate_id);
  v_com := public.screen_commitment(p_candidate_id);

  SELECT max(CASE WHEN construct='character'  THEN weight END),
         max(CASE WHEN construct='commitment' THEN weight END)
  INTO v_w_chr, v_w_com
  FROM public.hiregauge_layer_composite_weights WHERE layer='screen';

  IF v_chr IS NOT NULL THEN v_sum := v_sum + v_chr * v_w_chr; v_wsum := v_wsum + v_w_chr; END IF;
  IF v_com IS NOT NULL THEN v_sum := v_sum + v_com * v_w_com; v_wsum := v_wsum + v_w_com; END IF;

  capability_score := NULL;
  character_score := v_chr; commitment_score := v_com;
  composite := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;
  verdict := public._hiregauge_layer_verdict('screen', composite);
  RETURN NEXT;
END;
$function$;

COMMENT ON FUNCTION public.verdict_screen(uuid) IS
'Screen layer verdict — layer added 2026-08-13. Verdict-overall weights:
chr .05 / com .10 / cap 0 (screen_capability deliberately does not exist).
Research basis: see hiregauge_rules row "screen_layer_config"
(rule_type=screen_score_rubric).';

GRANT EXECUTE ON FUNCTION public.verdict_screen(uuid) TO authenticated, service_role;

COMMIT;
