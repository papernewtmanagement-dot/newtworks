-- Step 7 (retry): DROP + CREATE instead of CREATE OR REPLACE, since Postgres
-- won't let CREATE OR REPLACE VIEW remove a column. No dependent views/
-- functions on v_hiring_candidates (checked via pg_depend), safe to drop.

DROP VIEW public.v_hiring_candidates;

CREATE VIEW public.v_hiring_candidates AS
 WITH resume_w AS (
         SELECT max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'nature'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_nat,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'nurture'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_nur,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'drivers'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_dr
           FROM hiregauge_layer_composite_weights
          WHERE hiregauge_layer_composite_weights.layer = 'resume'::text
        ), assessment_w AS (
         SELECT max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'nature'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_nat,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'nurture'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_nur,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'drivers'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_dr
           FROM hiregauge_layer_composite_weights
          WHERE hiregauge_layer_composite_weights.layer = 'assessment'::text
        ), interview_w AS (
         SELECT max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'nature'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_nat,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'nurture'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_nur,
            max(
                CASE
                    WHEN hiregauge_layer_composite_weights.construct = 'drivers'::text THEN hiregauge_layer_composite_weights.weight
                    ELSE NULL::numeric
                END) AS w_dr
           FROM hiregauge_layer_composite_weights
          WHERE hiregauge_layer_composite_weights.layer = 'interview'::text
        ), iv_agg AS (
         SELECT hc_1.id AS hc_id,
            avg((((e.val -> 'scores'::text) -> 'nature'::text) ->> 'score'::text)::numeric) FILTER (WHERE (((e.val -> 'scores'::text) -> 'nature'::text) ->> 'score'::text) IS NOT NULL) AS avg_nature_raw,
            avg((((e.val -> 'scores'::text) -> 'nurture'::text) ->> 'score'::text)::numeric) FILTER (WHERE (((e.val -> 'scores'::text) -> 'nurture'::text) ->> 'score'::text) IS NOT NULL) AS avg_nurture_raw,
            avg((((e.val -> 'scores'::text) -> 'drivers'::text) ->> 'score'::text)::numeric) FILTER (WHERE (((e.val -> 'scores'::text) -> 'drivers'::text) ->> 'score'::text) IS NOT NULL) AS avg_drivers_raw
           FROM hiring_candidates hc_1
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
    resume_nature(hc.id) AS res_nature,
    resume_nurture(hc.id) AS res_nurture,
    resume_drivers(hc.id) AS res_drivers,
    round(rw.w_nat * COALESCE(resume_nature(hc.id), 0::numeric) + rw.w_nur * COALESCE(resume_nurture(hc.id), 0::numeric) + rw.w_dr * COALESCE(resume_drivers(hc.id), 0::numeric), 2) AS res_composite,
    assessment_nature(hc.id) AS assessment_nature,
    assessment_nurture(hc.id) AS assessment_nurture,
    assessment_drivers(hc.id) AS assessment_drivers,
    round(aw.w_nat * assessment_nature(hc.id) + aw.w_nur * COALESCE(assessment_nurture(hc.id), 0::numeric) + aw.w_dr * COALESCE(assessment_drivers(hc.id), 0::numeric), 2) AS assessment_composite,
    ns.honesty AS assessment_nurture_honesty,
    ns.concern AS assessment_nurture_concern,
    ns.work_ethic AS assessment_nurture_work_ethic,
    interview_nature(hc.id) AS iv_nature,
    interview_nurture(hc.id) AS iv_nurture,
    interview_drivers(hc.id) AS iv_drivers,
        CASE
            WHEN iv_agg.avg_nature_raw IS NULL AND iv_agg.avg_nurture_raw IS NULL AND iv_agg.avg_drivers_raw IS NULL THEN NULL::numeric
            ELSE round(COALESCE(iw.w_nat * (iv_agg.avg_nature_raw * 10::numeric), 0::numeric) + COALESCE(iw.w_nur * (iv_agg.avg_nurture_raw * 10::numeric), 0::numeric) + COALESCE(iw.w_dr * (iv_agg.avg_drivers_raw * 10::numeric), 0::numeric), 2)
        END AS iv_composite,
    hc.assessment_source
   FROM hiring_candidates hc
     CROSS JOIN resume_w rw
     CROSS JOIN assessment_w aw
     CROSS JOIN interview_w iw
     LEFT JOIN iv_agg ON iv_agg.hc_id = hc.id
     LEFT JOIN LATERAL ( SELECT
                CASE hc.response_distortion
                    WHEN 'low'::text THEN 85
                    WHEN 'moderate'::text THEN 50
                    WHEN 'high'::text THEN 15
                    ELSE NULL::integer
                END::numeric AS honesty,
                CASE
                    WHEN hc.compassion IS NOT NULL AND hc.belief_in_others IS NOT NULL THEN round(hc.compassion::numeric * 0.7 + hc.belief_in_others::numeric * 0.3, 2)
                    WHEN hc.compassion IS NOT NULL THEN hc.compassion::numeric
                    WHEN hc.belief_in_others IS NOT NULL THEN hc.belief_in_others::numeric
                    ELSE NULL::numeric
                END AS concern,
                CASE hc.reliability
                    WHEN 'high'::text THEN 85
                    WHEN 'moderate'::text THEN 50
                    WHEN 'low'::text THEN 15
                    ELSE NULL::integer
                END::numeric AS work_ethic) ns ON true;

-- Remove the dead branch from the generic trait-value getter (references the
-- column directly; must go before the DROP COLUMN). No live hiregauge_rules
-- row has trait_signature containing 'lss_total_ideal_min' — branch was
-- unreachable in practice.
CREATE OR REPLACE FUNCTION public._hiregauge_get_trait_value(p_ta hiring_candidates, p_trait text)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_trait
    WHEN 'deadline_motivation'     THEN p_ta.deadline_motivation::numeric
    WHEN 'recognition_drive'       THEN p_ta.recognition_drive::numeric
    WHEN 'assertiveness'           THEN p_ta.assertiveness::numeric
    WHEN 'independent_spirit'      THEN p_ta.independent_spirit::numeric
    WHEN 'analytical'              THEN p_ta.analytical::numeric
    WHEN 'compassion'              THEN p_ta.compassion::numeric
    WHEN 'self_promotion'          THEN p_ta.self_promotion::numeric
    WHEN 'belief_in_others'        THEN p_ta.belief_in_others::numeric
    WHEN 'optimism'                THEN p_ta.optimism::numeric
    WHEN 'overall_score'           THEN p_ta.overall_score::numeric
    WHEN 'lss_total_accuracy'      THEN p_ta.lss_total_accuracy::numeric
    WHEN 'maintains_high_activity' THEN
      (public.assessment_competency_maintains_high_activity(p_ta) ->> 'base')::numeric
    ELSE NULL
  END;
$function$;

-- Hard delete the column itself.
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS lss_total_ideal_min;
