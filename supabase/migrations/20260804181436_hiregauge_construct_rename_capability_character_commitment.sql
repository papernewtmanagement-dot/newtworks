-- Construct-axis rename: Nature/Nurture/Drivers -> Capability/Character/Commitment
--
-- Peter directive 2026-08-04. Research basis in persistent_memory.operational_rule
-- "Construct-axis research verdict 2026-08-04". Summary of why the old names went:
-- heritability does not partition traits (Turkheimer 2000, first law of behavior
-- genetics -- all behavioral traits are heritable), so "nature" vs "nurture" was
-- never a defensible split. Labeling a scored construct "innate" while scoring
-- anxiety/emotional-stability facets also sits closer than necessary to the
-- medical-exam line drawn in Karraker v. Rent-A-Center, 411 F.3d 831 (7th Cir. 2005).
-- "Character" restores Peter's own term from core_principles #550.
--
-- Three constructs stay three. The layer axis (resume/assessment/interview/reference)
-- holds METHODS; this axis holds CONSTRUCTS. Keeping them separate is the design
-- principle (Arthur & Villado 2008, JAP 93:435-442). No fourth construct: demonstrated
-- ability is a property of method, not of construct.
--
-- Construct weights stay 35/30/35. Justification is near-equal-weight robustness
-- absent a large local validation sample (Wainer 1976), NOT any source's literal split.
--
-- SCORING INPUTS ARE UNCHANGED BY THIS MIGRATION. This is a rename only. The known
-- invalid inputs to the character cell (honesty derived from response_distortion,
-- work ethic derived from reliability -- both response-style indices, not traits;
-- Ones, Viswesvaran & Reiss 1996) are deliberately preserved here and held for a
-- separate before/after review. Renaming and rescoring in one pass would make it
-- impossible to tell which change moved a verdict.
--
-- NOT renamed, deliberately: the `character_floor:` probe-source prefix in
-- custom_probes / interview_answers keys. That prefix predates and is independent of
-- the construct axis; it names a probe family, not a construct.

-- ---------------------------------------------------------------------------
-- 1. Snapshot the stored interview answers before rewriting their keys.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.hiring_candidates_interview_answers_bak_20260804 (
  candidate_id    uuid PRIMARY KEY,
  candidate_name  text,
  interview_answers jsonb,
  backed_up_at    timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.hiring_candidates_interview_answers_bak_20260804
  (candidate_id, candidate_name, interview_answers)
SELECT hc.id, hc.candidate_name, hc.interview_answers
FROM public.hiring_candidates hc
WHERE hc.interview_answers IS NOT NULL
  AND hc.interview_answers <> '{}'::jsonb
ON CONFLICT (candidate_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Drop dependents first: the view calls the construct functions directly.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS public.v_hiring_candidates;

DROP FUNCTION IF EXISTS public.verdict_overall(uuid, text);
DROP FUNCTION IF EXISTS public.verdict_resume(uuid);
DROP FUNCTION IF EXISTS public.verdict_assessment(uuid, text);
DROP FUNCTION IF EXISTS public.verdict_interview(uuid);
DROP FUNCTION IF EXISTS public.verdict_reference(uuid);

DROP FUNCTION IF EXISTS public.resume_nature(uuid);
DROP FUNCTION IF EXISTS public.resume_nurture(uuid);
DROP FUNCTION IF EXISTS public.resume_drivers(uuid);
DROP FUNCTION IF EXISTS public.assessment_nature(uuid, text);
DROP FUNCTION IF EXISTS public.assessment_nurture(uuid);
DROP FUNCTION IF EXISTS public.assessment_drivers(uuid);
DROP FUNCTION IF EXISTS public.interview_nature(uuid);
DROP FUNCTION IF EXISTS public.interview_nurture(uuid);
DROP FUNCTION IF EXISTS public.interview_drivers(uuid);
DROP FUNCTION IF EXISTS public.reference_nature(uuid);
DROP FUNCTION IF EXISTS public.reference_nurture(uuid);
DROP FUNCTION IF EXISTS public.reference_drivers(uuid);

-- ---------------------------------------------------------------------------
-- 3. Weights table. Every verdict function and the view look these rows up by
--    literal string, so the rows and the CHECK constraint have to move with the
--    function names or all four layer composites silently return NULL.
-- ---------------------------------------------------------------------------
ALTER TABLE public.hiregauge_layer_composite_weights
  DROP CONSTRAINT IF EXISTS hiregauge_layer_composite_weights_construct_check;

UPDATE public.hiregauge_layer_composite_weights
SET construct = CASE construct
                  WHEN 'nature'  THEN 'capability'
                  WHEN 'nurture' THEN 'character'
                  WHEN 'drivers' THEN 'commitment'
                  ELSE construct
                END,
    updated_at = now()
WHERE construct IN ('nature', 'nurture', 'drivers');

ALTER TABLE public.hiregauge_layer_composite_weights
  ADD CONSTRAINT hiregauge_layer_composite_weights_construct_check
  CHECK (construct = ANY (ARRAY['capability'::text, 'character'::text, 'commitment'::text]));

-- ---------------------------------------------------------------------------
-- 4. Stored interview answers: rewrite the score keys inside the jsonb.
--    Only the inner scores.<construct> keys move. Probe-source keys, answer
--    text, saved_at and graded_at are untouched.
-- ---------------------------------------------------------------------------
UPDATE public.hiring_candidates hc
SET interview_answers = (
      SELECT jsonb_object_agg(
               e.key,
               CASE
                 WHEN e.value ? 'scores' AND jsonb_typeof(e.value -> 'scores') = 'object'
                   THEN jsonb_set(
                          e.value,
                          '{scores}',
                          (SELECT COALESCE(
                                    jsonb_object_agg(
                                      CASE s.key
                                        WHEN 'nature'  THEN 'capability'
                                        WHEN 'nurture' THEN 'character'
                                        WHEN 'drivers' THEN 'commitment'
                                        ELSE s.key
                                      END,
                                      s.value),
                                    '{}'::jsonb)
                           FROM jsonb_each(e.value -> 'scores') s)
                        )
                 ELSE e.value
               END)
      FROM jsonb_each(hc.interview_answers) e
    ),
    updated_at = now()
WHERE hc.interview_answers IS NOT NULL
  AND hc.interview_answers <> '{}'::jsonb
  AND hc.interview_answers::text ~ '"(nature|nurture|drivers)"';

-- ---------------------------------------------------------------------------
-- 5. Construct functions, 4 layers x 3 constructs. Bodies are byte-identical to
--    the versions they replace apart from the renamed jsonb score keys.
-- ---------------------------------------------------------------------------

-- Resume layer: past-behavior evidence read off the resume.
CREATE FUNCTION public.resume_capability(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $function$
  WITH s AS (
    SELECT
      (hc.resume_analysis->'signals'->'autonomy'->>'score')::numeric                AS autonomy,
      (hc.resume_analysis->'signals'->'leadership_emergence'->>'score')::numeric    AS leadership_emergence,
      (hc.resume_analysis->'signals'->'interpersonal_substrate'->>'score')::numeric AS interpersonal_substrate
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
  )
  SELECT round((autonomy + leadership_emergence + interpersonal_substrate) / 3.0, 2)
  FROM s
  WHERE autonomy IS NOT NULL AND leadership_emergence IS NOT NULL AND interpersonal_substrate IS NOT NULL;
$function$;

CREATE FUNCTION public.resume_character(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $function$
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

CREATE FUNCTION public.resume_commitment(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $function$
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

-- Assessment layer: present-disposition self-report.
CREATE FUNCTION public.assessment_capability(p_candidate_id uuid, p_role text DEFAULT NULL::text)
RETURNS numeric LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_bf record;
  v_target text;
  v_result numeric;
BEGIN
  SELECT * INTO v_bf FROM public.assessment_best_fit_role(p_candidate_id);
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_target := COALESCE(p_role, v_bf.best_role);
  v_result := CASE v_target
    WHEN 'aspirant'             THEN v_bf.aspirant_fit_score
    WHEN 'sales_outbound'       THEN v_bf.sales_outbound_fit_score
    WHEN 'sales_inbound'        THEN v_bf.sales_inbound_fit_score
    WHEN 'sales_in_book'        THEN v_bf.sales_in_book_fit_score
    WHEN 'retention_reception'  THEN v_bf.retention_reception_fit_score
    WHEN 'retention_escalation' THEN v_bf.retention_escalation_fit_score
    WHEN 'retention_support'    THEN v_bf.retention_support_fit_score
    ELSE NULL
  END;
  RETURN v_result;
END;
$function$;

-- HELD, NOT FIXED: honesty is derived from response_distortion and work ethic from
-- reliability. Both are response-style indices rather than traits, and Ones,
-- Viswesvaran & Reiss 1996 (JAP) found social-desirability scales predict neither job
-- performance nor counterproductive behavior, recommending against correcting for
-- impression management in selection. The correct map reads the facets directly
-- (concern for others -> compassion + cooperation + trust; work ethic ->
-- self_discipline + achievement_striving + dutifulness; personal responsibility ->
-- dutifulness + self_efficacy; honesty has no facet and belongs to the interview and
-- reference layers). That rebuild is NOT applied here: zero candidates have v2 facets
-- populated, so switching today would blank honesty and work ethic on all 53 assessed
-- records including hired staff. Awaiting Peter's before/after review.
CREATE FUNCTION public.assessment_character(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $function$
  WITH parts AS (
    SELECT
      CASE hc.response_distortion
        WHEN 'low'      THEN 85
        WHEN 'moderate' THEN 50
        WHEN 'high'     THEN 15
        ELSE NULL
      END::numeric AS honesty,
      CASE
        WHEN hc.compassion IS NOT NULL AND hc.belief_in_others IS NOT NULL
          THEN round(hc.compassion::numeric * 0.7 + hc.belief_in_others::numeric * 0.3, 2)
        WHEN hc.compassion IS NOT NULL       THEN hc.compassion::numeric
        WHEN hc.belief_in_others IS NOT NULL THEN hc.belief_in_others::numeric
        ELSE NULL
      END AS concern,
      CASE hc.reliability
        WHEN 'high'     THEN 85
        WHEN 'moderate' THEN 50
        WHEN 'low'      THEN 15
        ELSE NULL
      END::numeric AS work_ethic
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
  )
  SELECT round(
    (COALESCE(honesty, 0::numeric) + COALESCE(concern, 0::numeric) + COALESCE(work_ethic, 0::numeric))
    / NULLIF(
        (CASE WHEN honesty    IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN concern    IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN work_ethic IS NOT NULL THEN 1 ELSE 0 END),
      0)::numeric,
    2)
  FROM parts;
$function$;

CREATE FUNCTION public.assessment_commitment(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $function$
  SELECT round(
    (hc.deadline_motivation + hc.recognition_drive + hc.independent_spirit)::numeric / 3.0,
    2)
  FROM public.hiring_candidates hc
  WHERE hc.id = p_candidate_id;
$function$;

-- Interview layer: structured past-behavior probes, graded per construct.
CREATE FUNCTION public.interview_capability(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $function$
  SELECT round(avg((((e.val -> 'scores') -> 'capability') ->> 'score')::numeric) * 10, 2)
  FROM public.hiring_candidates hc
  LEFT JOIN LATERAL jsonb_each(COALESCE(hc.interview_answers, '{}'::jsonb)) e(k, val) ON true
  WHERE hc.id = p_candidate_id
    AND (((e.val -> 'scores') -> 'capability') ->> 'score') IS NOT NULL;
$function$;

CREATE FUNCTION public.interview_character(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $function$
  SELECT round(avg((((e.val -> 'scores') -> 'character') ->> 'score')::numeric) * 10, 2)
  FROM public.hiring_candidates hc
  LEFT JOIN LATERAL jsonb_each(COALESCE(hc.interview_answers, '{}'::jsonb)) e(k, val) ON true
  WHERE hc.id = p_candidate_id
    AND (((e.val -> 'scores') -> 'character') ->> 'score') IS NOT NULL;
$function$;

CREATE FUNCTION public.interview_commitment(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $function$
  SELECT round(avg((((e.val -> 'scores') -> 'commitment') ->> 'score')::numeric) * 10, 2)
  FROM public.hiring_candidates hc
  LEFT JOIN LATERAL jsonb_each(COALESCE(hc.interview_answers, '{}'::jsonb)) e(k, val) ON true
  WHERE hc.id = p_candidate_id
    AND (((e.val -> 'scores') -> 'commitment') ->> 'score') IS NOT NULL;
$function$;

-- Reference layer: STUBS. All three return NULL, so 3 of the 12 matrix cells are dead.
-- Reference is the purest observed-behavior method available and filling these is
-- higher value than any further construct work. Renamed here to keep the axis
-- consistent; building them is separate scope.
CREATE FUNCTION public.reference_capability(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $function$ SELECT NULL::numeric $function$;

CREATE FUNCTION public.reference_character(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $function$ SELECT NULL::numeric $function$;

CREATE FUNCTION public.reference_commitment(p_candidate_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $function$ SELECT NULL::numeric $function$;

-- ---------------------------------------------------------------------------
-- 6. Layer verdict functions.
--    Output columns are suffixed _score because bare `character` is a PostgreSQL
--    keyword and cannot be an unquoted column name. Suffixing avoids a permanent
--    quoting trap and matches what verdict_overall already did.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.verdict_resume(p_candidate_id uuid)
RETURNS TABLE(capability_score numeric, character_score numeric, commitment_score numeric, composite numeric, verdict text)
LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_cap numeric; v_chr numeric; v_com numeric;
  v_w_cap numeric; v_w_chr numeric; v_w_com numeric;
  v_wsum numeric := 0; v_sum numeric := 0;
BEGIN
  v_cap := public.resume_capability(p_candidate_id);
  v_chr := public.resume_character(p_candidate_id);
  v_com := public.resume_commitment(p_candidate_id);

  SELECT max(CASE WHEN construct='capability' THEN weight END),
         max(CASE WHEN construct='character'  THEN weight END),
         max(CASE WHEN construct='commitment' THEN weight END)
  INTO v_w_cap, v_w_chr, v_w_com
  FROM public.hiregauge_layer_composite_weights WHERE layer='resume';

  IF v_cap IS NOT NULL THEN v_sum := v_sum + v_cap * v_w_cap; v_wsum := v_wsum + v_w_cap; END IF;
  IF v_chr IS NOT NULL THEN v_sum := v_sum + v_chr * v_w_chr; v_wsum := v_wsum + v_w_chr; END IF;
  IF v_com IS NOT NULL THEN v_sum := v_sum + v_com * v_w_com; v_wsum := v_wsum + v_w_com; END IF;

  capability_score := v_cap; character_score := v_chr; commitment_score := v_com;
  composite := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;
  verdict := public._hiregauge_layer_verdict('resume', composite);
  RETURN NEXT;
END;
$function$;

CREATE FUNCTION public.verdict_assessment(p_candidate_id uuid, p_role text DEFAULT NULL::text)
RETURNS TABLE(capability_score numeric, character_score numeric, commitment_score numeric, composite numeric, verdict text)
LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_cap numeric; v_chr numeric; v_com numeric;
  v_w_cap numeric; v_w_chr numeric; v_w_com numeric;
  v_wsum numeric := 0; v_sum numeric := 0;
BEGIN
  v_cap := public.assessment_capability(p_candidate_id, p_role);
  v_chr := public.assessment_character(p_candidate_id);
  v_com := public.assessment_commitment(p_candidate_id);

  SELECT max(CASE WHEN construct='capability' THEN weight END),
         max(CASE WHEN construct='character'  THEN weight END),
         max(CASE WHEN construct='commitment' THEN weight END)
  INTO v_w_cap, v_w_chr, v_w_com
  FROM public.hiregauge_layer_composite_weights WHERE layer='assessment';

  IF v_cap IS NOT NULL THEN v_sum := v_sum + v_cap * v_w_cap; v_wsum := v_wsum + v_w_cap; END IF;
  IF v_chr IS NOT NULL THEN v_sum := v_sum + v_chr * v_w_chr; v_wsum := v_wsum + v_w_chr; END IF;
  IF v_com IS NOT NULL THEN v_sum := v_sum + v_com * v_w_com; v_wsum := v_wsum + v_w_com; END IF;

  capability_score := v_cap; character_score := v_chr; commitment_score := v_com;
  composite := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;
  verdict := public._hiregauge_layer_verdict('assessment', composite);
  RETURN NEXT;
END;
$function$;

CREATE FUNCTION public.verdict_interview(p_candidate_id uuid)
RETURNS TABLE(capability_score numeric, character_score numeric, commitment_score numeric, composite numeric, verdict text)
LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_cap numeric; v_chr numeric; v_com numeric;
  v_w_cap numeric; v_w_chr numeric; v_w_com numeric;
  v_wsum numeric := 0; v_sum numeric := 0;
BEGIN
  v_cap := public.interview_capability(p_candidate_id);
  v_chr := public.interview_character(p_candidate_id);
  v_com := public.interview_commitment(p_candidate_id);

  SELECT max(CASE WHEN construct='capability' THEN weight END),
         max(CASE WHEN construct='character'  THEN weight END),
         max(CASE WHEN construct='commitment' THEN weight END)
  INTO v_w_cap, v_w_chr, v_w_com
  FROM public.hiregauge_layer_composite_weights WHERE layer='interview';

  IF v_cap IS NOT NULL THEN v_sum := v_sum + v_cap * v_w_cap; v_wsum := v_wsum + v_w_cap; END IF;
  IF v_chr IS NOT NULL THEN v_sum := v_sum + v_chr * v_w_chr; v_wsum := v_wsum + v_w_chr; END IF;
  IF v_com IS NOT NULL THEN v_sum := v_sum + v_com * v_w_com; v_wsum := v_wsum + v_w_com; END IF;

  capability_score := v_cap; character_score := v_chr; commitment_score := v_com;
  composite := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;
  verdict := public._hiregauge_layer_verdict('interview', composite);
  RETURN NEXT;
END;
$function$;

CREATE FUNCTION public.verdict_reference(p_candidate_id uuid)
RETURNS TABLE(capability_score numeric, character_score numeric, commitment_score numeric, composite numeric, verdict text)
LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_cap numeric; v_chr numeric; v_com numeric;
  v_w_cap numeric; v_w_chr numeric; v_w_com numeric;
  v_wsum numeric := 0; v_sum numeric := 0;
BEGIN
  v_cap := public.reference_capability(p_candidate_id);
  v_chr := public.reference_character(p_candidate_id);
  v_com := public.reference_commitment(p_candidate_id);

  SELECT max(CASE WHEN construct='capability' THEN weight END),
         max(CASE WHEN construct='character'  THEN weight END),
         max(CASE WHEN construct='commitment' THEN weight END)
  INTO v_w_cap, v_w_chr, v_w_com
  FROM public.hiregauge_layer_composite_weights WHERE layer='reference';

  IF v_cap IS NOT NULL THEN v_sum := v_sum + v_cap * v_w_cap; v_wsum := v_wsum + v_w_cap; END IF;
  IF v_chr IS NOT NULL THEN v_sum := v_sum + v_chr * v_w_chr; v_wsum := v_wsum + v_w_chr; END IF;
  IF v_com IS NOT NULL THEN v_sum := v_sum + v_com * v_w_com; v_wsum := v_wsum + v_w_com; END IF;

  capability_score := v_cap; character_score := v_chr; commitment_score := v_com;
  composite := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;
  verdict := public._hiregauge_layer_verdict('reference', composite);
  RETURN NEXT;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 7. Overall verdict. Construct weights 35/30/35 unchanged; layer weights within
--    each construct unchanged.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.verdict_overall(p_candidate_id uuid, p_role text DEFAULT NULL::text)
RETURNS TABLE(candidate_id uuid, verdict text, score_0_10 numeric, score_hire_at_70 text, score_hire_at_75 text, score_hire_at_80 text, resume_score numeric, resume_verdict text, assessment_score numeric, assessment_verdict text, interview_score numeric, interview_verdict text, reference_score numeric, reference_verdict text, capability_score numeric, character_score numeric, commitment_score numeric, dimensions_scored integer, confidence text, meta jsonb)
LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_ta record; v_r record; v_a record; v_i record; v_ref record; v_best record;
  v_lss_autopass jsonb; v_lss_status text; v_dims int := 0;
  v_cap_r_w numeric := 0.05; v_cap_a_w numeric := 0.75; v_cap_i_w numeric := 0.15; v_cap_ref_w numeric := 0.05;
  v_chr_r_w numeric := 0.10; v_chr_a_w numeric := 0.15; v_chr_i_w numeric := 0.45; v_chr_ref_w numeric := 0.30;
  v_com_r_w numeric := 0.10; v_com_a_w numeric := 0.15; v_com_i_w numeric := 0.45; v_com_ref_w numeric := 0.30;
  v_cap_w numeric := 0.35; v_chr_w numeric := 0.30; v_com_w numeric := 0.35;
  v_wsum numeric; v_sum numeric;
BEGIN
  SELECT * INTO v_ta FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT * INTO v_r    FROM public.verdict_resume(p_candidate_id);
  SELECT * INTO v_a    FROM public.verdict_assessment(p_candidate_id, p_role);
  SELECT * INTO v_i    FROM public.verdict_interview(p_candidate_id);
  SELECT * INTO v_ref  FROM public.verdict_reference(p_candidate_id);
  SELECT * INTO v_best FROM public.assessment_best_fit_role(p_candidate_id);

  IF v_r.capability_score IS NOT NULL OR v_r.character_score IS NOT NULL OR v_r.commitment_score IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_a.capability_score   IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_a.character_score    IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_a.commitment_score   IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_i.capability_score   IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_i.character_score    IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_i.commitment_score   IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_ref.capability_score IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_ref.character_score  IS NOT NULL THEN v_dims := v_dims + 1; END IF;
  IF v_ref.commitment_score IS NOT NULL THEN v_dims := v_dims + 1; END IF;

  v_wsum := 0; v_sum := 0;
  IF v_r.capability_score   IS NOT NULL THEN v_sum := v_sum + v_r.capability_score   * v_cap_r_w;   v_wsum := v_wsum + v_cap_r_w;   END IF;
  IF v_a.capability_score   IS NOT NULL THEN v_sum := v_sum + v_a.capability_score   * v_cap_a_w;   v_wsum := v_wsum + v_cap_a_w;   END IF;
  IF v_i.capability_score   IS NOT NULL THEN v_sum := v_sum + v_i.capability_score   * v_cap_i_w;   v_wsum := v_wsum + v_cap_i_w;   END IF;
  IF v_ref.capability_score IS NOT NULL THEN v_sum := v_sum + v_ref.capability_score * v_cap_ref_w; v_wsum := v_wsum + v_cap_ref_w; END IF;
  capability_score := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;

  v_wsum := 0; v_sum := 0;
  IF v_r.character_score   IS NOT NULL THEN v_sum := v_sum + v_r.character_score   * v_chr_r_w;   v_wsum := v_wsum + v_chr_r_w;   END IF;
  IF v_a.character_score   IS NOT NULL THEN v_sum := v_sum + v_a.character_score   * v_chr_a_w;   v_wsum := v_wsum + v_chr_a_w;   END IF;
  IF v_i.character_score   IS NOT NULL THEN v_sum := v_sum + v_i.character_score   * v_chr_i_w;   v_wsum := v_wsum + v_chr_i_w;   END IF;
  IF v_ref.character_score IS NOT NULL THEN v_sum := v_sum + v_ref.character_score * v_chr_ref_w; v_wsum := v_wsum + v_chr_ref_w; END IF;
  character_score := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;

  v_wsum := 0; v_sum := 0;
  IF v_r.commitment_score   IS NOT NULL THEN v_sum := v_sum + v_r.commitment_score   * v_com_r_w;   v_wsum := v_wsum + v_com_r_w;   END IF;
  IF v_a.commitment_score   IS NOT NULL THEN v_sum := v_sum + v_a.commitment_score   * v_com_a_w;   v_wsum := v_wsum + v_com_a_w;   END IF;
  IF v_i.commitment_score   IS NOT NULL THEN v_sum := v_sum + v_i.commitment_score   * v_com_i_w;   v_wsum := v_wsum + v_com_i_w;   END IF;
  IF v_ref.commitment_score IS NOT NULL THEN v_sum := v_sum + v_ref.commitment_score * v_com_ref_w; v_wsum := v_wsum + v_com_ref_w; END IF;
  commitment_score := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;

  v_wsum := 0; v_sum := 0;
  IF capability_score IS NOT NULL THEN v_sum := v_sum + capability_score * v_cap_w; v_wsum := v_wsum + v_cap_w; END IF;
  IF character_score  IS NOT NULL THEN v_sum := v_sum + character_score  * v_chr_w; v_wsum := v_wsum + v_chr_w; END IF;
  IF commitment_score IS NOT NULL THEN v_sum := v_sum + commitment_score * v_com_w; v_wsum := v_wsum + v_com_w; END IF;
  score_0_10 := CASE WHEN v_wsum > 0 THEN round(v_sum / v_wsum, 2) ELSE NULL END;

  resume_score     := v_r.composite;    resume_verdict     := v_r.verdict;
  assessment_score := v_a.composite;    assessment_verdict := v_a.verdict;
  interview_score  := v_i.composite;    interview_verdict  := v_i.verdict;
  reference_score  := v_ref.composite;  reference_verdict  := v_ref.verdict;

  v_lss_autopass := public._hiregauge_lss_autopass(
    v_ta.lss_total_accuracy, v_ta.reliability, v_ta.analytical::numeric,
    v_best.best_role,
    v_ta.resume_analysis->'qualifications'->'licenses',
    v_ta.resume_analysis->'qualifications'->'education',
    v_ta.resume_analysis->'qualifications'->'prior_similar_role'
  );
  v_lss_status := v_lss_autopass->>'status';
  verdict := CASE
    WHEN score_0_10 IS NULL THEN 'insufficient_data'
    WHEN v_lss_status = 'decline_lss' THEN 'decline_lss'
    ELSE (CASE public._hiregauge_layer_verdict('framework', score_0_10)
            WHEN 'pass' THEN 'hire'
            WHEN 'consider' THEN 'consider'
            ELSE 'decline'
          END)
  END;
  score_hire_at_70 := CASE WHEN score_0_10 IS NULL THEN 'n/a' WHEN score_0_10 >= 70 THEN 'hire' WHEN score_0_10 >= 55 THEN 'consider' ELSE 'decline' END;
  score_hire_at_75 := CASE WHEN score_0_10 IS NULL THEN 'n/a' WHEN score_0_10 >= 75 THEN 'hire' WHEN score_0_10 >= 60 THEN 'consider' ELSE 'decline' END;
  score_hire_at_80 := CASE WHEN score_0_10 IS NULL THEN 'n/a' WHEN score_0_10 >= 80 THEN 'hire' WHEN score_0_10 >= 65 THEN 'consider' ELSE 'decline' END;
  candidate_id := p_candidate_id;
  dimensions_scored := v_dims;
  confidence := CASE WHEN v_dims >= 9 THEN 'high' WHEN v_dims >= 5 THEN 'medium' ELSE 'low' END;
  meta := jsonb_build_object(
    'matrix', jsonb_build_object(
      'capability', jsonb_build_object('resume', v_r.capability_score, 'assessment', v_a.capability_score, 'interview', v_i.capability_score, 'reference', v_ref.capability_score),
      'character',  jsonb_build_object('resume', v_r.character_score,  'assessment', v_a.character_score,  'interview', v_i.character_score,  'reference', v_ref.character_score),
      'commitment', jsonb_build_object('resume', v_r.commitment_score, 'assessment', v_a.commitment_score, 'interview', v_i.commitment_score, 'reference', v_ref.commitment_score)),
    'construct_weights', jsonb_build_object(
      'capability', v_cap_w,
      'character',  v_chr_w,
      'commitment', v_com_w),
    'construct_weight_basis', 'near-equal weights, robust absent a large local validation sample (Wainer 1976)',
    'layer_weights_within_construct', jsonb_build_object(
      'capability', jsonb_build_object('resume', v_cap_r_w, 'assessment', v_cap_a_w, 'interview', v_cap_i_w, 'reference', v_cap_ref_w),
      'character',  jsonb_build_object('resume', v_chr_r_w, 'assessment', v_chr_a_w, 'interview', v_chr_i_w, 'reference', v_chr_ref_w),
      'commitment', jsonb_build_object('resume', v_com_r_w, 'assessment', v_com_a_w, 'interview', v_com_i_w, 'reference', v_com_ref_w)),
    'role_used_for_assessment_capability', COALESCE(p_role, v_best.best_role),
    'best_fit_role', v_best.best_role,
    'best_fit_score', v_best.best_fit_score,
    'lss_autopass',  v_lss_autopass);
  RETURN NEXT;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 8. Rebuild the candidate view. Output columns renamed to match the axis.
-- ---------------------------------------------------------------------------
CREATE VIEW public.v_hiring_candidates AS
WITH resume_w AS (
  SELECT max(CASE WHEN construct='capability' THEN weight END) AS w_cap,
         max(CASE WHEN construct='character'  THEN weight END) AS w_chr,
         max(CASE WHEN construct='commitment' THEN weight END) AS w_com
  FROM public.hiregauge_layer_composite_weights WHERE layer='resume'
), assessment_w AS (
  SELECT max(CASE WHEN construct='capability' THEN weight END) AS w_cap,
         max(CASE WHEN construct='character'  THEN weight END) AS w_chr,
         max(CASE WHEN construct='commitment' THEN weight END) AS w_com
  FROM public.hiregauge_layer_composite_weights WHERE layer='assessment'
), interview_w AS (
  SELECT max(CASE WHEN construct='capability' THEN weight END) AS w_cap,
         max(CASE WHEN construct='character'  THEN weight END) AS w_chr,
         max(CASE WHEN construct='commitment' THEN weight END) AS w_com
  FROM public.hiregauge_layer_composite_weights WHERE layer='interview'
), iv_agg AS (
  SELECT hc_1.id AS hc_id,
    avg((((e.val -> 'scores') -> 'capability') ->> 'score')::numeric) FILTER (WHERE (((e.val -> 'scores') -> 'capability') ->> 'score') IS NOT NULL) AS avg_capability_raw,
    avg((((e.val -> 'scores') -> 'character')  ->> 'score')::numeric) FILTER (WHERE (((e.val -> 'scores') -> 'character')  ->> 'score') IS NOT NULL) AS avg_character_raw,
    avg((((e.val -> 'scores') -> 'commitment') ->> 'score')::numeric) FILTER (WHERE (((e.val -> 'scores') -> 'commitment') ->> 'score') IS NOT NULL) AS avg_commitment_raw
  FROM public.hiring_candidates hc_1
    LEFT JOIN LATERAL jsonb_each(COALESCE(hc_1.interview_answers, '{}'::jsonb)) e(k, val) ON true
  GROUP BY hc_1.id
)
SELECT hc.id,
  hc.agency_id,
  hc.team_member_id,
  hc.assessment_date,
  hc.overall_score,
  hc.reliability,
  hc.response_distortion,
  hc.deadline_motivation,
  hc.recognition_drive,
  hc.assertiveness,
  hc.independent_spirit,
  hc.analytical,
  hc.compassion,
  hc.self_promotion,
  hc.belief_in_others,
  hc.optimism,
  hc.lss_math_accuracy,
  hc.lss_verbal_accuracy,
  hc.lss_problem_solving_accuracy,
  hc.lss_total_accuracy,
  hc.lss_math_speed_seconds,
  hc.lss_verbal_speed_seconds,
  hc.lss_problem_solving_speed_seconds,
  hc.notes,
  hc.created_at,
  hc.updated_at,
  hc.candidate_name,
  hc.first_name,
  hc.last_name,
  hc.email,
  hc.phone,
  hc."position",
  hc.status,
  hc.status_updated_at,
  hc.resume_document_id,
  hc.resume_url,
  hc.claude_summary,
  hc.final_decision,
  hc.decision_at,
  hc.decision_notes,
  hc.decline_reason,
  hc.custom_probes,
  hc.custom_probes_generated_at,
  hc.applied_at,
  hc.resume_extracted_text,
  hc.resume_analysis,
  hc.ingestion_metadata,
  hc.assessment_timing,
  hc.ai_analysis,
  hc.interview_analysis,
  hc.interview_answers,
  public.resume_capability(hc.id) AS res_capability,
  public.resume_character(hc.id)  AS res_character,
  public.resume_commitment(hc.id) AS res_commitment,
  round(rw.w_cap * COALESCE(public.resume_capability(hc.id), 0::numeric)
      + rw.w_chr * COALESCE(public.resume_character(hc.id),  0::numeric)
      + rw.w_com * COALESCE(public.resume_commitment(hc.id), 0::numeric), 2) AS res_composite,
  public.assessment_capability(hc.id) AS assessment_capability,
  public.assessment_character(hc.id)  AS assessment_character,
  public.assessment_commitment(hc.id) AS assessment_commitment,
  round(aw.w_cap * public.assessment_capability(hc.id)
      + aw.w_chr * COALESCE(public.assessment_character(hc.id),  0::numeric)
      + aw.w_com * COALESCE(public.assessment_commitment(hc.id), 0::numeric), 2) AS assessment_composite,
  ns.honesty    AS assessment_character_honesty,
  ns.concern    AS assessment_character_concern,
  ns.work_ethic AS assessment_character_work_ethic,
  public.interview_capability(hc.id) AS iv_capability,
  public.interview_character(hc.id)  AS iv_character,
  public.interview_commitment(hc.id) AS iv_commitment,
  CASE
    WHEN iv_agg.avg_capability_raw IS NULL AND iv_agg.avg_character_raw IS NULL AND iv_agg.avg_commitment_raw IS NULL THEN NULL::numeric
    ELSE round(COALESCE(iw.w_cap * (iv_agg.avg_capability_raw * 10::numeric), 0::numeric)
             + COALESCE(iw.w_chr * (iv_agg.avg_character_raw  * 10::numeric), 0::numeric)
             + COALESCE(iw.w_com * (iv_agg.avg_commitment_raw * 10::numeric), 0::numeric), 2)
  END AS iv_composite,
  hc.assessment_source
FROM public.hiring_candidates hc
  CROSS JOIN resume_w rw
  CROSS JOIN assessment_w aw
  CROSS JOIN interview_w iw
  LEFT JOIN iv_agg ON iv_agg.hc_id = hc.id
  LEFT JOIN LATERAL (
    SELECT
      CASE hc.response_distortion
        WHEN 'low'      THEN 85
        WHEN 'moderate' THEN 50
        WHEN 'high'     THEN 15
        ELSE NULL::integer
      END::numeric AS honesty,
      CASE
        WHEN hc.compassion IS NOT NULL AND hc.belief_in_others IS NOT NULL
          THEN round(hc.compassion::numeric * 0.7 + hc.belief_in_others::numeric * 0.3, 2)
        WHEN hc.compassion IS NOT NULL       THEN hc.compassion::numeric
        WHEN hc.belief_in_others IS NOT NULL THEN hc.belief_in_others::numeric
        ELSE NULL::numeric
      END AS concern,
      CASE hc.reliability
        WHEN 'high'     THEN 85
        WHEN 'moderate' THEN 50
        WHEN 'low'      THEN 15
        ELSE NULL::integer
      END::numeric AS work_ethic
  ) ns ON true;

GRANT SELECT ON public.v_hiring_candidates TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.v_hiring_candidates TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.v_hiring_candidates TO service_role;

-- ---------------------------------------------------------------------------
-- 9. Published rubric rows. Display labels and prose only; no scoring behavior.
--    Sub-signal names after the colon (Autonomy, Honesty, ...) are unchanged.
-- ---------------------------------------------------------------------------
UPDATE public.hiregauge_rules
SET rule_name = 'Capability: ' || substring(rule_name from 9), updated_at = now()
WHERE rule_type = 'resume_score_rubric' AND rule_name LIKE 'Nature: %';

UPDATE public.hiregauge_rules
SET rule_name = 'Character: ' || substring(rule_name from 10), updated_at = now()
WHERE rule_type = 'resume_score_rubric' AND rule_name LIKE 'Nurture: %';

UPDATE public.hiregauge_rules
SET rule_name = 'Commitment: ' || substring(rule_name from 10), updated_at = now()
WHERE rule_type = 'resume_score_rubric' AND rule_name LIKE 'Drivers: %';

UPDATE public.hiregauge_rules
SET description = regexp_replace(regexp_replace(regexp_replace(
      COALESCE(description,''),
      '\yNature\y', 'Capability', 'g'), '\yNurture\y', 'Character', 'g'), '\yDrivers\y', 'Commitment', 'g'),
    notes = regexp_replace(regexp_replace(regexp_replace(
      COALESCE(notes,''),
      '\yNature\y', 'Capability', 'g'), '\yNurture\y', 'Character', 'g'), '\yDrivers\y', 'Commitment', 'g'),
    updated_at = now()
WHERE rule_type IN ('resume_score_rubric','interview_score_rubric')
  AND (COALESCE(description,'') || COALESCE(notes,'')) ~ '\y(Nature|Nurture|Drivers)\y';

UPDATE public.hiregauge_rules
SET description = regexp_replace(regexp_replace(regexp_replace(
      COALESCE(description,''),
      '\ynature\y', 'capability', 'g'), '\ynurture\y', 'character', 'g'), '\ydrivers\y', 'commitment', 'g'),
    notes = regexp_replace(regexp_replace(regexp_replace(
      COALESCE(notes,''),
      '\ynature\y', 'capability', 'g'), '\ynurture\y', 'character', 'g'), '\ydrivers\y', 'commitment', 'g'),
    updated_at = now()
WHERE rule_type IN ('resume_score_rubric','interview_score_rubric')
  AND (COALESCE(description,'') || COALESCE(notes,'')) ~ '\y(nature|nurture|drivers)\y';

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_set(
      trait_signature,
      '{construct_weights}',
      jsonb_build_object(
        'capability', trait_signature->'construct_weights'->'nature',
        'character',  trait_signature->'construct_weights'->'nurture',
        'commitment', trait_signature->'construct_weights'->'drivers')),
    updated_at = now()
WHERE rule_type = 'resume_score_rubric'
  AND trait_signature ? 'construct_weights'
  AND trait_signature->'construct_weights' ? 'nature';

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_set(
      trait_signature,
      '{subsignal_averaging}',
      to_jsonb(regexp_replace(regexp_replace(regexp_replace(
        trait_signature->>'subsignal_averaging',
        '\yNature\y', 'Capability', 'g'), '\yNurture\y', 'Character', 'g'), '\yDrivers\y', 'Commitment', 'g'))),
    updated_at = now()
WHERE rule_type = 'resume_score_rubric'
  AND trait_signature ? 'subsignal_averaging';

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_set(
      trait_signature,
      '{domain_awareness_note}',
      to_jsonb(regexp_replace(regexp_replace(regexp_replace(
        trait_signature->>'domain_awareness_note',
        '\yNature\y', 'Capability', 'g'), '\yNurture\y', 'Character', 'g'), '\yDrivers\y', 'Commitment', 'g'))),
    updated_at = now()
WHERE rule_type = 'resume_score_rubric'
  AND trait_signature ? 'domain_awareness_note';
