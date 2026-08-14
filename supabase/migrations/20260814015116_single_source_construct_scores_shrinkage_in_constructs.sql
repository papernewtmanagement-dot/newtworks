-- SINGLE-SOURCE REFACTOR (Peter directive 2026-08-13): every surface that shows or
-- consumes a Character or Commitment number must get it from ONE function, and the
-- validity math must live in ONE place. Before this migration the shrinkage formula
-- existed in verdict_assessment AND inline in v_hiring_candidates (the inline copy fell
-- behind once already, today), while raw un-shrunk constructs still leaked out through
-- the view columns and the interview gap triggers. After this migration:
--   * _newtworks_shrink() is the only home of the Kelley shrinkage formula.
--   * assessment_character()/assessment_commitment() RETURN the validity-adjusted
--     construct. There is no raw construct API anymore; raw is reconstructable as
--     (score - (1-v)*50)/v for the N=50 recalibration if ever needed.
--   * _assessment_character_parts() returns validity-adjusted parts, so the three
--     sub-rows on CandidateDetail visually average to the construct row (shrinkage is
--     linear, so shrinking parts == shrinking their mean, up to cents of rounding).
--   * verdict_assessment() no longer shrinks -- it only weights -- and becomes the one
--     place composite math lives. SECURITY DEFINER for the same RLS-per-row perf
--     reason as the leaf functions (20260813224026).
--   * v_hiring_candidates takes capability/character/commitment/composite/validity from
--     ONE verdict_assessment lateral. Zero scoring arithmetic remains in the view; the
--     only CASE left is the display gate that hides composites for legacy facet rows
--     that never took the assessment (capability NULL), which is a surfacing rule, not
--     math (verdict_assessment deliberately renormalizes partial constructs for
--     verdict_overall's benefit).
-- Facet-level scores (the 25-facet table) intentionally remain RAW: they are the
-- evidence record of what the candidate actually answered; constructs and up are the
-- believed values. Downstream effects: interview gap triggers (T_GAP_*) now compare
-- resume vs believed assessment constructs instead of raw -- fewer spurious probes off
-- low-validity protocols. verdict_overall and auto_decline already consumed
-- verdict_assessment (shrunk) values and are numerically unchanged.

-- 1) The one home of the shrinkage formula.
CREATE OR REPLACE FUNCTION public._newtworks_shrink(p_score numeric, p_v numeric)
RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $$
  -- Kelley 1927 regressed estimate toward the population-mean anchor (50 on the
  -- percentile scale); Nunnally & Bernstein 1994. NULL score stays NULL; missing v
  -- treated as fully trusted.
  SELECT CASE WHEN p_score IS NULL THEN NULL
              ELSE round(COALESCE(p_v, 1.0) * p_score + (1 - COALESCE(p_v, 1.0)) * 50, 2)
         END;
$$;
REVOKE ALL ON FUNCTION public._newtworks_shrink(numeric, numeric) FROM anon;

-- 2) Character parts: validity-adjusted at the source. assessment_character() averages
-- these, so it inherits the adjustment with no change to its own body.
CREATE OR REPLACE FUNCTION public._assessment_character_parts(p_candidate_id uuid)
 RETURNS TABLE(concern numeric, work_ethic numeric, personal_responsibility numeric)
 LANGUAGE sql
 STABLE
AS $function$
  -- role_fit_v5_0_facet_direct_2026_08_06 / Migration E: percentile-wrapped,
  -- same divisor rule as assessment_commitment (E.1).
  -- 2026-08-13 single-source refactor: each part is validity-adjusted here via
  -- _newtworks_shrink so every consumer (assessment_character, the CandidateDetail
  -- sub-rows) sees the same believed values and sub-rows average to the construct.
  WITH f AS (
    SELECT
      public.hiregauge_facet_percentile(hc.agency_id, 'compassion', hc.compassion)::numeric AS compassion,
      public.hiregauge_facet_percentile(hc.agency_id, 'cooperation', hc.cooperation)::numeric AS cooperation,
      public.hiregauge_facet_percentile(hc.agency_id, 'trust', hc.trust)::numeric AS trust,
      public.hiregauge_facet_percentile(hc.agency_id, 'self_discipline', hc.self_discipline)::numeric AS self_discipline,
      public.hiregauge_facet_percentile(hc.agency_id, 'achievement_striving', hc.achievement_striving)::numeric AS achievement_striving,
      public.hiregauge_facet_percentile(hc.agency_id, 'dutifulness', hc.dutifulness)::numeric AS dutifulness,
      public.hiregauge_facet_percentile(hc.agency_id, 'self_efficacy', hc.self_efficacy)::numeric AS self_efficacy,
      (public._newtworks_protocol_validity(hc.*) ->> 'v')::numeric AS v
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
  )
  SELECT
    public._newtworks_shrink(
      round((COALESCE(compassion,0) + COALESCE(cooperation,0) + COALESCE(trust,0))
        / NULLIF((compassion IS NOT NULL)::int
               + (cooperation IS NOT NULL)::int + (trust IS NOT NULL)::int, 0), 2), v),
    public._newtworks_shrink(
      round((COALESCE(self_discipline,0) + COALESCE(achievement_striving,0) + COALESCE(dutifulness,0))
        / NULLIF((self_discipline IS NOT NULL)::int + (achievement_striving IS NOT NULL)::int
               + (dutifulness IS NOT NULL)::int, 0), 2), v),
    public._newtworks_shrink(
      round((COALESCE(dutifulness,0) + COALESCE(self_efficacy,0))
        / NULLIF((dutifulness IS NOT NULL)::int + (self_efficacy IS NOT NULL)::int, 0), 2), v)
  FROM f;
$function$;

-- 3) Commitment: validity-adjusted at the end of the same single function.
CREATE OR REPLACE FUNCTION public.assessment_commitment(p_candidate_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- role_fit_v5_0_facet_direct_2026_08_06 / Migration E: percentile inputs, E.1
  -- divisor rule (divisor counts non-null PERCENTILES).
  -- 2026-08-13 single-source refactor: returns the validity-adjusted construct via
  -- _newtworks_shrink; there is no separate raw-construct API.
  WITH c AS (
    SELECT
      public.hiregauge_facet_percentile(hc.agency_id, 'enterprising', hc.enterprising) AS p_enterprising,
      public.hiregauge_facet_percentile(hc.agency_id, 'achievement_striving', hc.achievement_striving) AS p_achievement_striving,
      public.hiregauge_facet_percentile(hc.agency_id, 'competitiveness', hc.competitiveness) AS p_competitiveness,
      public.hiregauge_facet_percentile(hc.agency_id, 'prove_goal_orientation', hc.prove_goal_orientation) AS p_prove_goal_orientation,
      public.hiregauge_facet_percentile(hc.agency_id, 'learning_goal_orientation', hc.learning_goal_orientation) AS p_learning_goal_orientation,
      public.hiregauge_facet_percentile(hc.agency_id, 'avoid_goal_orientation', hc.avoid_goal_orientation) AS p_avoid_goal_orientation,
      (public._newtworks_protocol_validity(hc.*) ->> 'v')::numeric AS v
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
      AND hc.achievement_striving IS NOT NULL
  )
  SELECT
    public._newtworks_shrink(
      round(
        (COALESCE(p_enterprising,0) + COALESCE(p_achievement_striving,0)
         + COALESCE(p_competitiveness,0) + COALESCE(p_prove_goal_orientation,0)
         + COALESCE(p_learning_goal_orientation,0)
         + COALESCE(100 - p_avoid_goal_orientation, 0))::numeric
        / NULLIF(
            (p_enterprising IS NOT NULL)::int + (p_achievement_striving IS NOT NULL)::int
            + (p_competitiveness IS NOT NULL)::int + (p_prove_goal_orientation IS NOT NULL)::int
            + (p_learning_goal_orientation IS NOT NULL)::int + (p_avoid_goal_orientation IS NOT NULL)::int,
          0)
      , 2), c.v)
  FROM c;
$function$;

-- 4) assessment_character: body re-shipped verbatim (averages the parts, which are now
-- validity-adjusted -- inheritance, no formula here).
CREATE OR REPLACE FUNCTION public.assessment_character(p_candidate_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT round(
    (COALESCE(p.concern,0) + COALESCE(p.work_ethic,0) + COALESCE(p.personal_responsibility,0))
    / NULLIF((p.concern IS NOT NULL)::int
           + (p.work_ethic IS NOT NULL)::int
           + (p.personal_responsibility IS NOT NULL)::int, 0), 2)
  FROM public._assessment_character_parts(p_candidate_id) p;
$function$;

-- 5) verdict_assessment: weighting only; constructs arrive already validity-adjusted.
CREATE OR REPLACE FUNCTION public.verdict_assessment(p_candidate_id uuid, p_role text DEFAULT NULL::text)
 RETURNS TABLE(capability_score numeric, character_score numeric, commitment_score numeric, composite numeric, verdict text, protocol_validity jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
/*
2026-08-13 single-source refactor. Shrinkage no longer happens here: it moved into
the construct functions themselves (_assessment_character_parts /
assessment_commitment via _newtworks_shrink), so assessment_character() and
assessment_commitment() ARE the one Character and Commitment number everywhere --
detail page, board, gap triggers, this verdict. This function only weights the three
construct outputs per hiregauge_layer_composite_weights and labels the verdict.
Capability carries validity through role fit's own weight renormalization
(_newtworks_role_fit_core) and is never shrunk -- doing both would double-apply v to
the same evidence (unchanged rule). SECURITY DEFINER for the same per-row RLS cost
reason as the leaf construct functions (20260813224026).
*/
DECLARE
  v_candidate hiring_candidates;
  v_cap numeric; v_chr numeric; v_com numeric;
  v_w_cap numeric; v_w_chr numeric; v_w_com numeric;
  v_wsum numeric := 0; v_sum numeric := 0;
BEGIN
  SELECT * INTO v_candidate FROM public.hiring_candidates WHERE id = p_candidate_id;

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
  protocol_validity := public._newtworks_protocol_validity(v_candidate);
  RETURN NEXT;
END;
$function$;
REVOKE ALL ON FUNCTION public.verdict_assessment(uuid, text) FROM anon;

-- 6) View: one verdict_assessment lateral supplies every assessment number.
CREATE OR REPLACE VIEW public.v_hiring_candidates
WITH (security_invoker = true) AS
 WITH resume_w AS (
         SELECT max(CASE WHEN construct = 'capability' THEN weight END) AS w_cap,
                max(CASE WHEN construct = 'character'  THEN weight END) AS w_chr,
                max(CASE WHEN construct = 'commitment' THEN weight END) AS w_com
           FROM hiregauge_layer_composite_weights
          WHERE layer = 'resume'
        ), interview_w AS (
         SELECT max(CASE WHEN construct = 'capability' THEN weight END) AS w_cap,
                max(CASE WHEN construct = 'character'  THEN weight END) AS w_chr,
                max(CASE WHEN construct = 'commitment' THEN weight END) AS w_com
           FROM hiregauge_layer_composite_weights
          WHERE layer = 'interview'
        ), iv_agg AS (
         SELECT hc_1.id AS hc_id,
            avg((((e.val -> 'scores') -> 'capability') ->> 'score')::numeric) FILTER (WHERE (((e.val -> 'scores') -> 'capability') ->> 'score') IS NOT NULL) AS avg_capability_raw,
            avg((((e.val -> 'scores') -> 'character') ->> 'score')::numeric) FILTER (WHERE (((e.val -> 'scores') -> 'character') ->> 'score') IS NOT NULL) AS avg_character_raw,
            avg((((e.val -> 'scores') -> 'commitment') ->> 'score')::numeric) FILTER (WHERE (((e.val -> 'scores') -> 'commitment') ->> 'score') IS NOT NULL) AS avg_commitment_raw
           FROM hiring_candidates hc_1
             LEFT JOIN LATERAL jsonb_each(COALESCE(hc_1.interview_answers, '{}'::jsonb)) e(k, val) ON true
          GROUP BY hc_1.id
        )
 SELECT hc.id,
    hc.agency_id,
    hc.team_member_id,
    hc.reliability,
    hc.assertiveness,
    hc.compassion,
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
    resume_capability(hc.id) AS res_capability,
    resume_character(hc.id) AS res_character,
    resume_commitment(hc.id) AS res_commitment,
    resume_weighted_composite(hc.resume_analysis) AS res_composite,
    va.capability_score AS assessment_capability,
    va.character_score AS assessment_character,
    va.commitment_score AS assessment_commitment,
    CASE WHEN va.capability_score IS NULL THEN NULL ELSE va.composite END AS assessment_composite,
    ns.concern AS assessment_character_concern,
    ns.work_ethic AS assessment_character_work_ethic,
    ns.personal_responsibility AS assessment_character_personal_resp,
    interview_capability(hc.id) AS iv_capability,
    interview_character(hc.id) AS iv_character,
    interview_commitment(hc.id) AS iv_commitment,
        CASE
            WHEN iv_agg.avg_capability_raw IS NULL AND iv_agg.avg_character_raw IS NULL AND iv_agg.avg_commitment_raw IS NULL THEN NULL::numeric
            ELSE round(COALESCE(iw.w_cap * (iv_agg.avg_capability_raw * 10::numeric), 0::numeric) + COALESCE(iw.w_chr * (iv_agg.avg_character_raw * 10::numeric), 0::numeric) + COALESCE(iw.w_com * (iv_agg.avg_commitment_raw * 10::numeric), 0::numeric), 2)
        END AS iv_composite,
    hc.assessment_source,
    hc.gma_pattern_accuracy,
    hc.gma_numerical_accuracy,
    hc.gma_deductive_accuracy,
    hc.gma_verbal_accuracy,
    hc.gma_total_accuracy,
    hc.gma_pattern_speed_seconds,
    hc.gma_numerical_speed_seconds,
    hc.gma_deductive_speed_seconds,
    hc.gma_verbal_speed_seconds,
    hc.sjt_score,
    hc.sjt_topic_detail,
    hc.reliability_detail,
    hc.impression_management,
    hc.impression_management_band,
    hc.impression_management_detail,
    hc.assessment_started_at,
    hc.assessment_completed_at,
    hc.assessment_exit_gate,
    hc.assessment_exit_detail,
    hc.assessment_exited_at,
    screen_character(hc.id) AS screen_character,
    screen_commitment(hc.id) AS screen_commitment,
    va.protocol_validity,
    (va.protocol_validity ->> 'v')::numeric AS protocol_validity_v,
    va.protocol_validity ->> 'label' AS protocol_validity_label
   FROM hiring_candidates hc
     CROSS JOIN resume_w rw
     CROSS JOIN interview_w iw
     LEFT JOIN iv_agg ON iv_agg.hc_id = hc.id
     LEFT JOIN LATERAL _assessment_character_parts(hc.id) ns(concern, work_ethic, personal_responsibility) ON true
     LEFT JOIN LATERAL verdict_assessment(hc.id, NULL) va ON true;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.v_hiring_candidates FROM authenticated;
REVOKE ALL ON public.v_hiring_candidates FROM anon;
