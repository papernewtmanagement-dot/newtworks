-- CORRECTION to assessment_character_rebuild_real_facets, same session.
-- That migration substituted belief_in_others for trust when trust was null. Peter
-- directed the correct facet map with blanks accepted; substituting a different column
-- for a named facet is not the correct map and was not authorized. Removed.
--
-- Concern for Others now reads exactly compassion, cooperation, trust. Nothing stands
-- in for a missing facet. A facet with no data contributes nothing and the component
-- averages over whatever genuinely has data. If nothing has data, the component is NULL.
--
-- Effect today: cooperation and trust are unpopulated, so Concern for Others equals
-- compassion alone. Hard Work Ethic and Personal Responsibility are NULL. Character
-- therefore equals compassion until candidates complete the current assessment.
--
-- Also rebuilds v_hiring_candidates so its Character breakdown columns match:
--   DROPPED  assessment_character_honesty (the response_distortion derivation, gone)
--   KEPT     assessment_character_concern, assessment_character_work_ethic
--   ADDED    assessment_character_personal_resp
-- The breakdown reads from _assessment_character_parts() instead of a duplicated
-- inline lateral, so the view and the scoring function cannot drift apart.

CREATE OR REPLACE FUNCTION public._assessment_character_parts(p_candidate_id uuid)
RETURNS TABLE(concern numeric, work_ethic numeric, personal_responsibility numeric)
LANGUAGE sql STABLE AS $function$
  WITH f AS (
    SELECT hc.compassion::numeric           AS compassion,
           hc.cooperation::numeric          AS cooperation,
           hc.trust::numeric                AS trust,
           hc.self_discipline::numeric      AS self_discipline,
           hc.achievement_striving::numeric AS achievement_striving,
           hc.dutifulness::numeric          AS dutifulness,
           hc.self_efficacy::numeric        AS self_efficacy
    FROM public.hiring_candidates hc
    WHERE hc.id = p_candidate_id
  )
  SELECT
    round((COALESCE(compassion,0) + COALESCE(cooperation,0) + COALESCE(trust,0))
      / NULLIF((compassion IS NOT NULL)::int + (cooperation IS NOT NULL)::int
             + (trust IS NOT NULL)::int, 0), 2),
    round((COALESCE(self_discipline,0) + COALESCE(achievement_striving,0) + COALESCE(dutifulness,0))
      / NULLIF((self_discipline IS NOT NULL)::int + (achievement_striving IS NOT NULL)::int
             + (dutifulness IS NOT NULL)::int, 0), 2),
    round((COALESCE(dutifulness,0) + COALESCE(self_efficacy,0))
      / NULLIF((dutifulness IS NOT NULL)::int + (self_efficacy IS NOT NULL)::int, 0), 2)
  FROM f;
$function$;

DROP VIEW IF EXISTS public.v_hiring_candidates;

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
  ns.concern                 AS assessment_character_concern,
  ns.work_ethic              AS assessment_character_work_ethic,
  ns.personal_responsibility AS assessment_character_personal_resp,
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
  LEFT JOIN LATERAL public._assessment_character_parts(hc.id) ns ON true;

GRANT SELECT ON public.v_hiring_candidates TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.v_hiring_candidates TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.v_hiring_candidates TO service_role;
