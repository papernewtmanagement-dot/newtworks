-- ============================================================
-- Step 7B: DESTRUCTIVE — rebuild v_hiring_candidates without 17 flat cols
-- + DROP 27 legacy flat cols
-- Frontend already reads jsonb paths (commit 72af8cb, deployed). Backfill
-- shipped in 7A. Jsonb source cols (assessment_timing, interview_analysis,
-- ai_analysis) remain the canonical shape going forward.
-- ============================================================

DROP VIEW IF EXISTS public.v_hiring_candidates CASCADE;
CREATE VIEW public.v_hiring_candidates AS
WITH resume_w AS (
  SELECT
    max(CASE WHEN construct='nature'  THEN weight END) AS w_nat,
    max(CASE WHEN construct='nurture' THEN weight END) AS w_nur,
    max(CASE WHEN construct='drivers' THEN weight END) AS w_dr
  FROM hiregauge_layer_composite_weights WHERE layer='resume'
),
assessment_w AS (
  SELECT
    max(CASE WHEN construct='nature'  THEN weight END) AS w_nat,
    max(CASE WHEN construct='nurture' THEN weight END) AS w_nur,
    max(CASE WHEN construct='drivers' THEN weight END) AS w_dr
  FROM hiregauge_layer_composite_weights WHERE layer='assessment'
),
interview_w AS (
  SELECT
    max(CASE WHEN construct='nature'  THEN weight END) AS w_nat,
    max(CASE WHEN construct='nurture' THEN weight END) AS w_nur,
    max(CASE WHEN construct='drivers' THEN weight END) AS w_dr
  FROM hiregauge_layer_composite_weights WHERE layer='interview'
),
iv_agg AS (
  SELECT hc.id AS hc_id,
    avg(((e.val->'scores'->'nature'->>'score'))::numeric)
      FILTER (WHERE (e.val->'scores'->'nature'->>'score') IS NOT NULL)   AS avg_nature_raw,
    avg(((e.val->'scores'->'nurture'->>'score'))::numeric)
      FILTER (WHERE (e.val->'scores'->'nurture'->>'score') IS NOT NULL)  AS avg_nurture_raw,
    avg(((e.val->'scores'->'drivers'->>'score'))::numeric)
      FILTER (WHERE (e.val->'scores'->'drivers'->>'score') IS NOT NULL)  AS avg_drivers_raw
  FROM hiring_candidates hc
  LEFT JOIN LATERAL jsonb_each(COALESCE(hc.interview_answers,'{}'::jsonb)) e(k,val) ON true
  GROUP BY hc.id
)
SELECT
  hc.id, hc.agency_id, hc.team_member_id, hc.assessment_date,
  hc.overall_score, hc.reliability, hc.response_distortion,
  hc.deadline_motivation, hc.recognition_drive, hc.assertiveness,
  hc.independent_spirit, hc.analytical, hc.compassion, hc.self_promotion,
  hc.belief_in_others, hc.optimism,
  hc.lss_math_accuracy, hc.lss_verbal_accuracy, hc.lss_problem_solving_accuracy,
  hc.lss_total_accuracy, hc.lss_total_ideal_min,
  hc.lss_math_speed_seconds, hc.lss_verbal_speed_seconds, hc.lss_problem_solving_speed_seconds,
  hc.notes, hc.created_at, hc.updated_at,
  hc.candidate_name, hc.first_name, hc.last_name, hc.email, hc.phone,
  hc."position", hc.status, hc.status_updated_at,
  hc.resume_document_id, hc.resume_url,
  hc.claude_summary, hc.final_decision, hc.decision_at, hc.decision_notes,
  hc.decline_reason, hc.custom_probes, hc.custom_probes_generated_at,
  hc.applied_at,
  hc.resume_extracted_text, hc.resume_analysis,
  hc.ingestion_metadata, hc.assessment_timing, hc.ai_analysis, hc.interview_analysis,
  hc.interview_answers,
  resume_nature(hc.id)  AS res_nature,
  resume_nurture(hc.id) AS res_nurture,
  resume_drivers(hc.id) AS res_drivers,
  round(
    (rw.w_nat * COALESCE(resume_nature(hc.id),0)
    + rw.w_nur * COALESCE(resume_nurture(hc.id),0)
    + rw.w_dr  * COALESCE(resume_drivers(hc.id),0)), 2
  ) AS res_composite,
  assessment_nature(hc.id)  AS assessment_nature,
  assessment_nurture(hc.id) AS assessment_nurture,
  assessment_drivers(hc.id) AS assessment_drivers,
  round(
    (aw.w_nat * assessment_nature(hc.id)
    + aw.w_nur * COALESCE(assessment_nurture(hc.id),0)
    + aw.w_dr  * COALESCE(assessment_drivers(hc.id),0)), 2
  ) AS assessment_composite,
  ns.honesty     AS assessment_nurture_honesty,
  ns.concern     AS assessment_nurture_concern,
  ns.work_ethic  AS assessment_nurture_work_ethic,
  interview_nature(hc.id)  AS iv_nature,
  interview_nurture(hc.id) AS iv_nurture,
  interview_drivers(hc.id) AS iv_drivers,
  CASE
    WHEN iv_agg.avg_nature_raw IS NULL AND iv_agg.avg_nurture_raw IS NULL AND iv_agg.avg_drivers_raw IS NULL THEN NULL
    ELSE round(
      COALESCE(iw.w_nat * (iv_agg.avg_nature_raw  * 10), 0)
    + COALESCE(iw.w_nur * (iv_agg.avg_nurture_raw * 10), 0)
    + COALESCE(iw.w_dr  * (iv_agg.avg_drivers_raw * 10), 0), 2
    )
  END AS iv_composite
FROM hiring_candidates hc
CROSS JOIN resume_w rw
CROSS JOIN assessment_w aw
CROSS JOIN interview_w iw
LEFT JOIN iv_agg ON iv_agg.hc_id = hc.id
LEFT JOIN LATERAL (
  SELECT
    (CASE hc.response_distortion
      WHEN 'low'      THEN 85
      WHEN 'moderate' THEN 50
      WHEN 'high'     THEN 15
      ELSE NULL
    END)::numeric AS honesty,
    CASE
      WHEN hc.compassion IS NOT NULL AND hc.belief_in_others IS NOT NULL
        THEN round((hc.compassion::numeric*0.7 + hc.belief_in_others::numeric*0.3), 2)
      WHEN hc.compassion IS NOT NULL       THEN hc.compassion::numeric
      WHEN hc.belief_in_others IS NOT NULL THEN hc.belief_in_others::numeric
      ELSE NULL
    END AS concern,
    (CASE hc.reliability
      WHEN 'high'     THEN 85
      WHEN 'moderate' THEN 50
      WHEN 'low'      THEN 15
      ELSE NULL
    END)::numeric AS work_ethic
) ns ON true;

GRANT SELECT ON public.v_hiring_candidates TO anon;
GRANT ALL    ON public.v_hiring_candidates TO authenticated, service_role, postgres;

-- Now drop 27 flat cols (12 timing + 10 gt_* + 5 interview flat)
ALTER TABLE public.hiring_candidates
  DROP COLUMN IF EXISTS cts_invited_at,
  DROP COLUMN IF EXISTS cts_started_at,
  DROP COLUMN IF EXISTS cts_completed_at,
  DROP COLUMN IF EXISTS cts_wall_duration_seconds,
  DROP COLUMN IF EXISTS epq_started_at,
  DROP COLUMN IF EXISTS epq_completed_at,
  DROP COLUMN IF EXISTS lss_started_at,
  DROP COLUMN IF EXISTS lss_completed_at,
  DROP COLUMN IF EXISTS lss_wall_duration_seconds,
  DROP COLUMN IF EXISTS vct_started_at,
  DROP COLUMN IF EXISTS vct_completed_at,
  DROP COLUMN IF EXISTS vct_wall_duration_seconds,
  DROP COLUMN IF EXISTS gt_alt_seats,
  DROP COLUMN IF EXISTS gt_archetype,
  DROP COLUMN IF EXISTS gt_best_fit_seat,
  DROP COLUMN IF EXISTS gt_character_floor_status,
  DROP COLUMN IF EXISTS gt_coaching_variant,
  DROP COLUMN IF EXISTS gt_confidence,
  DROP COLUMN IF EXISTS gt_decline_category,
  DROP COLUMN IF EXISTS gt_extracted_at,
  DROP COLUMN IF EXISTS gt_extraction_notes,
  DROP COLUMN IF EXISTS gt_motivator_family,
  DROP COLUMN IF EXISTS iv_scored_at,
  DROP COLUMN IF EXISTS iv_verdict,
  DROP COLUMN IF EXISTS iv_verdict_reason,
  DROP COLUMN IF EXISTS interview_analysis_text,
  DROP COLUMN IF EXISTS interview_analysis_at;
