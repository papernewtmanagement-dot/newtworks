-- ============================================================
-- Step 5A: rewire upsert_candidate_from_careerplug + view + backfill
-- Non-destructive. Prep for 5B col drops.
-- ============================================================

-- 1. Backfill 2 old-shape-only rows into new ingestion_metadata shape
UPDATE public.hiring_candidates
SET ingestion_metadata = jsonb_build_object(
  'source', COALESCE(candidate_source, 'careerplug'),
  'ingested_at', COALESCE(applied_at, created_at),
  'careerplug', jsonb_build_object(
    'raw_line',                careerplug_metadata->>'raw_line',
    'is_fast_track',           (nullif(careerplug_metadata->>'is_fast_track',''))::boolean,
    'prescreen_score',         (nullif(careerplug_metadata->>'prescreen_score',''))::int,
    'source_platform',         careerplug_metadata->>'source_platform',
    'careerplug_applicant_id', careerplug_metadata->>'careerplug_applicant_id'
  ),
  'source_message', jsonb_build_object(
    'gmail_from',       careerplug_metadata->>'gmail_from',
    'gmail_subject',    careerplug_metadata->>'gmail_subject',
    'gmail_message_id', COALESCE(source_gmail_message_id, careerplug_metadata->>'gmail_source_message_id')
  )
)
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND ingestion_metadata IS NULL
  AND careerplug_metadata IS NOT NULL;

-- 2. Rewire fn — writes to ingestion_metadata only, reads Layer 1 idempotency
--    from jsonb path. Payload shape from parser unchanged (still sends
--    gmail_message_id top-level and careerplug_metadata sub-object) — fn
--    translates internally.
CREATE OR REPLACE FUNCTION public.upsert_candidate_from_careerplug(p_agency_id uuid, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_existing_id      uuid;
  v_email            text := lower(nullif(p_payload->>'email',''));
  v_gmail_msg_id     text := nullif(p_payload->>'gmail_message_id','');
  v_first_name       text := nullif(p_payload->>'first_name','');
  v_last_name        text := nullif(p_payload->>'last_name','');
  v_candidate_name   text;
  v_phone            text := nullif(p_payload->>'phone','');
  v_position         text := nullif(p_payload->>'position','');
  v_applied_at       timestamptz;
  v_resume_url       text := nullif(p_payload->>'resume_url','');
  v_resume_doc_id    uuid;
  v_meta             jsonb := coalesce(p_payload->'careerplug_metadata','{}'::jsonb);
  v_ingestion        jsonb;
BEGIN
  v_candidate_name := trim(concat_ws(' ', v_first_name, v_last_name));
  IF v_candidate_name = '' THEN
    v_candidate_name := coalesce(nullif(p_payload->>'candidate_name',''), v_email);
  END IF;

  BEGIN
    v_applied_at := (p_payload->>'applied_at')::timestamptz;
  EXCEPTION WHEN OTHERS THEN
    v_applied_at := now();
  END;
  IF v_applied_at IS NULL THEN
    v_applied_at := now();
  END IF;

  BEGIN
    v_resume_doc_id := nullif(p_payload->>'resume_document_id','')::uuid;
  EXCEPTION WHEN OTHERS THEN
    v_resume_doc_id := NULL;
  END;

  -- Build new-shape ingestion_metadata from parser payload
  v_ingestion := jsonb_build_object(
    'source',       'careerplug',
    'ingested_at',  now(),
    'careerplug',   jsonb_build_object(
      'raw_line',                v_meta->>'raw_line',
      'is_fast_track',           (nullif(v_meta->>'is_fast_track',''))::boolean,
      'prescreen_score',         (nullif(v_meta->>'prescreen_score',''))::int,
      'source_platform',         v_meta->>'source_platform',
      'careerplug_applicant_id', v_meta->>'careerplug_applicant_id'
    ),
    'source_message', jsonb_build_object(
      'gmail_from',       v_meta->>'gmail_from',
      'gmail_subject',    v_meta->>'gmail_subject',
      'gmail_message_id', v_gmail_msg_id
    )
  );

  -- Layer 1: idempotency by gmail_message_id (new: via ingestion_metadata jsonb path)
  IF v_gmail_msg_id IS NOT NULL THEN
    SELECT id INTO v_existing_id
    FROM public.hiring_candidates
    WHERE agency_id = p_agency_id
      AND ingestion_metadata->'source_message'->>'gmail_message_id' = v_gmail_msg_id
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'assessment_id', v_existing_id,
        'action', 'noop_by_gmail_message_id'
      );
    END IF;
  END IF;

  -- Layer 2: dedup by email
  IF v_email IS NOT NULL THEN
    SELECT id INTO v_existing_id
    FROM public.hiring_candidates
    WHERE agency_id = p_agency_id
      AND lower(email) = v_email
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
      UPDATE public.hiring_candidates
      SET
        first_name         = coalesce(first_name, v_first_name),
        last_name          = coalesce(last_name,  v_last_name),
        candidate_name     = coalesce(candidate_name, v_candidate_name),
        phone              = coalesce(phone, v_phone),
        position           = coalesce(position, v_position),
        applied_at         = coalesce(applied_at, v_applied_at),
        resume_url         = coalesce(resume_url, v_resume_url),
        resume_document_id = coalesce(resume_document_id, v_resume_doc_id),
        ingestion_metadata = coalesce(ingestion_metadata, '{}'::jsonb) || v_ingestion,
        updated_at         = now()
      WHERE id = v_existing_id;

      RETURN jsonb_build_object(
        'assessment_id', v_existing_id,
        'action', 'updated_by_email'
      );
    END IF;
  END IF;

  -- Layer 3: INSERT new candidate at status='applied'
  INSERT INTO public.hiring_candidates (
    agency_id, assessment_date, candidate_name, first_name, last_name,
    email, phone, position, status, status_updated_at, applied_at,
    resume_url, resume_document_id, ingestion_metadata
  ) VALUES (
    p_agency_id, v_applied_at::date, v_candidate_name, v_first_name, v_last_name,
    v_email, v_phone, v_position, 'applied', v_applied_at, v_applied_at,
    v_resume_url, v_resume_doc_id, v_ingestion
  )
  RETURNING id INTO v_existing_id;

  RETURN jsonb_build_object(
    'assessment_id', v_existing_id,
    'action', 'inserted'
  );
END;
$function$;

-- 3. Index for new Layer 1 idempotency path
CREATE INDEX IF NOT EXISTS idx_hiring_candidates_ingestion_gmail_msg
  ON public.hiring_candidates ((ingestion_metadata->'source_message'->>'gmail_message_id'))
  WHERE ingestion_metadata->'source_message'->>'gmail_message_id' IS NOT NULL;

-- 4. Rebuild v_hiring_candidates without the 3 cols (candidate_source,
--    careerplug_metadata, source_gmail_message_id). No downstream deps.
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
  hc.cts_wall_duration_seconds, hc.lss_wall_duration_seconds, hc.vct_wall_duration_seconds,
  hc.decline_reason, hc.custom_probes, hc.custom_probes_generated_at,
  hc.applied_at,
  hc.resume_extracted_text, hc.resume_analysis,
  hc.ingestion_metadata, hc.assessment_timing, hc.ai_analysis, hc.interview_analysis,
  hc.cts_invited_at, hc.cts_started_at, hc.cts_completed_at,
  hc.epq_started_at, hc.epq_completed_at,
  hc.vct_started_at, hc.vct_completed_at,
  hc.lss_started_at, hc.lss_completed_at,
  hc.interview_answers, hc.interview_analysis_text, hc.interview_analysis_at,
  hc.iv_verdict, hc.iv_verdict_reason, hc.iv_scored_at,
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
