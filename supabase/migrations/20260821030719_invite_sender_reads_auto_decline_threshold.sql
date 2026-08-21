CREATE OR REPLACE FUNCTION public.send_v1_assessment_invitations(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_first_sent int := 0;
  v_reminder_sent int := 0;
  v_errors int := 0;
  v_max_per_run int := 10;
  v_cand RECORD;
  v_link_path text;
  v_full_link text;
  v_app_url text := 'https://newtworks.vercel.app';
  v_subject text;
  v_html text;
  v_pg_net_id bigint;
  v_position_display text;
  v_role_phrase text;
  v_next_attempt timestamptz;
  v_sent_ids uuid[] := ARRAY[]::uuid[];
  v_reminded_ids uuid[] := ARRAY[]::uuid[];
  v_completed_swept int := 0;
  v_declined_swept int := 0;
  v_exited_swept int := 0;
  v_no_response_swept int := 0;
  v_resume_score_gated int := 0;
  v_error_details jsonb := '[]'::jsonb;
  v_resume_consider_threshold numeric;
  v_records_processed int;
  v_output_summary text;
  v_done_alert_types text[] := ARRAY['v1_assessment_complete', 'v2_assessment_complete'];
BEGIN
  SELECT pass_threshold INTO v_resume_consider_threshold
  FROM public.hiregauge_verdict_thresholds WHERE layer = 'resume';

  IF v_resume_consider_threshold IS NULL THEN
    RETURN jsonb_build_object('error', 'resume verdict threshold row missing — refusing to send', 'ran_at', NOW(),
      'records_processed', 0, 'output_summary', 'ERROR: resume verdict threshold row missing — refusing to send');
  END IF;

  -- Change (2026-08-20, Peter directive): invite eligibility reads the
  -- routing-only auto_decline_threshold, falling back to consider_threshold
  -- when unset. Keeps "who gets invited" separate from the published resume
  -- verdict label band.
  SELECT COALESCE(auto_decline_threshold, consider_threshold) INTO v_resume_consider_threshold
  FROM public.hiregauge_verdict_thresholds WHERE layer = 'resume';

  -- Step 1a: Completion sweep
  WITH updated AS (
    UPDATE public.assessment_invitations ai
    SET outcome = 'completed', updated_at = NOW()
    WHERE ai.agency_id = p_agency_id
      AND ai.outcome = 'sent'
      AND EXISTS (
        SELECT 1 FROM public.alerts a
        WHERE a.agency_id = p_agency_id
          AND a.alert_type = ANY (v_done_alert_types)
          AND a.related_id = ai.candidate_id
      )
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_completed_swept FROM updated;

  -- Step 1b: Declined sweep
  WITH updated AS (
    UPDATE public.assessment_invitations ai
    SET outcome = 'declined', updated_at = NOW()
    WHERE ai.agency_id = p_agency_id
      AND ai.outcome = 'sent'
      AND ai.candidate_id IN (
        SELECT hc.id FROM public.hiring_candidates hc
        WHERE hc.agency_id = p_agency_id AND hc.status = 'declined'
      )
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_declined_swept FROM updated;

  -- Step 1c: Exit-gate sweep. Terminal — the candidate was removed at the
  -- stint-1 screen and was told nothing. They must never receive another
  -- reminder, and they are not a 'no_response'.
  WITH updated AS (
    UPDATE public.assessment_invitations ai
    SET outcome = 'exited', updated_at = NOW()
    WHERE ai.agency_id = p_agency_id
      AND ai.outcome = 'sent'
      AND ai.candidate_id IN (
        SELECT hc.id FROM public.hiring_candidates hc
        WHERE hc.agency_id = p_agency_id
          AND hc.assessment_exit_gate IS NOT NULL
      )
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_exited_swept FROM updated;

  -- Step 1d: Resume-score gate sweep — candidates sitting eligible for
  -- attempt 1 but blocked by the resume layer: below the routing floor
  -- (or never scored) AND not qualifying for the early-career lane.
  SELECT COUNT(*) INTO v_resume_score_gated
  FROM public.hiring_candidates hc
  WHERE hc.agency_id = p_agency_id
    AND hc.status = 'applied'
    AND hc.email IS NOT NULL
    AND hc.email <> ''
    AND hc.assessment_exit_gate IS NULL
    AND NOT EXISTS (SELECT 1 FROM public.assessment_invitations ai WHERE ai.candidate_id = hc.id)
    AND (
      hc.resume_analysis IS NULL
      OR public.resume_weighted_composite(hc.resume_analysis) IS NULL
      OR (
        public.resume_weighted_composite(hc.resume_analysis) < v_resume_consider_threshold
        AND NOT (
          (hc.resume_analysis->>'early_career') = 'true'
          AND hc.integrity_flag IS NOT TRUE
          AND (
            ( COALESCE((hc.resume_analysis#>>'{signals,honesty,score}')::numeric, 0)
            + COALESCE((hc.resume_analysis#>>'{signals,concern_for_others,score}')::numeric, 0)
            + COALESCE((hc.resume_analysis#>>'{signals,hard_work_ethic,score}')::numeric, 0)
            + COALESCE((hc.resume_analysis#>>'{signals,personal_responsibility,score}')::numeric, 0)
            + COALESCE((hc.resume_analysis#>>'{signals,presentation,score}')::numeric, 0)
            ) / 5.0
          ) >= 40
        )
      )
    );

  -- Step 2a: Attempt 1 — new candidates with no prior invitations.
  FOR v_cand IN
    SELECT hc.id, hc.first_name, hc.last_name, hc.email, hc.position
    FROM public.hiring_candidates hc
    WHERE hc.agency_id = p_agency_id
      AND hc.status = 'applied'
      AND hc.email IS NOT NULL
      AND hc.email <> ''
      AND hc.assessment_exit_gate IS NULL
      AND hc.resume_analysis IS NOT NULL
      AND (
        public.resume_weighted_composite(hc.resume_analysis) >= v_resume_consider_threshold
        OR (
          (hc.resume_analysis->>'early_career') = 'true'
          AND hc.integrity_flag IS NOT TRUE
          AND (
            ( COALESCE((hc.resume_analysis#>>'{signals,honesty,score}')::numeric, 0)
            + COALESCE((hc.resume_analysis#>>'{signals,concern_for_others,score}')::numeric, 0)
            + COALESCE((hc.resume_analysis#>>'{signals,hard_work_ethic,score}')::numeric, 0)
            + COALESCE((hc.resume_analysis#>>'{signals,personal_responsibility,score}')::numeric, 0)
            + COALESCE((hc.resume_analysis#>>'{signals,presentation,score}')::numeric, 0)
            ) / 5.0
          ) >= 40
        )
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.assessment_invitations ai
        WHERE ai.candidate_id = hc.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.alerts a
        WHERE a.agency_id = p_agency_id
          AND a.alert_type = ANY (v_done_alert_types)
          AND a.related_id = hc.id
      )
    ORDER BY hc.applied_at NULLS LAST, hc.created_at
    LIMIT v_max_per_run
  LOOP
    BEGIN
      v_link_path := public.mint_v1_assessment_link(v_cand.id);
      v_full_link := v_app_url || v_link_path;
      v_position_display := COALESCE(NULLIF(v_cand.position, ''), 'the role');

      v_role_phrase := CASE
        WHEN v_cand.position IS NOT NULL AND v_cand.position <> ''
          THEN 'the <strong>' || v_cand.position || '</strong> role'
        ELSE 'this role'
      END;

      v_subject := 'Assessment for ' || v_position_display || ' at Peter Story State Farm';

      v_html :=
        '<p>Hi ' || COALESCE(v_cand.first_name, 'there') || ',</p>' ||
        '<p>Thanks for applying for ' || v_role_phrase ||
          ' at Peter Story State Farm.</p>' ||
        '<p>Before we schedule any live conversation, please work through this short ' ||
          'assessment. It takes about 30 minutes and covers personality, working style, ' ||
          'and a bit of aptitude. Nothing to study for &mdash; just answer honestly.</p>' ||
        '<p>This works both ways. It is a chance for me to learn how you naturally think ' ||
          'and work &mdash; and a chance for you to see whether this role suits the way ' ||
          'you like to work. The best hires I have made have felt like the right fit for ' ||
          'both sides.</p>' ||
        '<p><a href="' || v_full_link || '" style="display:inline-block;padding:12px 24px;' ||
          'background:#737A59;color:#ffffff;text-decoration:none;border-radius:6px;' ||
          'font-weight:600;">Start the assessment</a></p>' ||
        '<p style="color:#64748b;font-size:13px;">If the button does not work, paste this ' ||
          'link into your browser:<br><a href="' || v_full_link || '">' || v_full_link || '</a></p>' ||
        '<p>Once you are done, I will review your results along with a short set of written ' ||
          'questions I will send next. If we are a fit, we will schedule a video call.</p>' ||
        '<p>&mdash; Peter Story<br>Peter Story State Farm</p>';

      v_pg_net_id := public.composio_send_email(p_agency_id, v_cand.email, v_subject, v_html);

      INSERT INTO public.assessment_invitations
        (agency_id, candidate_id, attempt_number, sent_at, pg_net_request_id, subject, outcome, next_attempt_at)
      VALUES
        (p_agency_id, v_cand.id, 1, NOW(), v_pg_net_id, v_subject, 'sent', NOW() + INTERVAL '1 day');

      UPDATE public.hiring_candidates
      SET status = 'assessment_sent'
      WHERE id = v_cand.id AND status = 'applied';

      v_first_sent := v_first_sent + 1;
      v_sent_ids := array_append(v_sent_ids, v_cand.id);
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors + 1;
      v_error_details := v_error_details || jsonb_build_object(
        'stage', 'attempt_1',
        'candidate_id', v_cand.id,
        'error', SQLERRM
      );
    END;
  END LOOP;

  -- Step 2b: Reminder sends — attempts 2 & 3 (latest attempt due).
  FOR v_cand IN
    SELECT hc.id, hc.first_name, hc.last_name, hc.email, hc.position,
           latest.attempt_number AS last_attempt
    FROM public.hiring_candidates hc
    JOIN LATERAL (
      SELECT ai.attempt_number, ai.outcome, ai.next_attempt_at
      FROM public.assessment_invitations ai
      WHERE ai.candidate_id = hc.id
        AND ai.agency_id = p_agency_id
      ORDER BY ai.attempt_number DESC
      LIMIT 1
    ) latest ON true
    WHERE hc.agency_id = p_agency_id
      AND hc.status IN ('applied', 'assessment_sent')
      AND hc.email IS NOT NULL
      AND hc.email <> ''
      AND hc.assessment_exit_gate IS NULL
      AND latest.outcome = 'sent'
      AND latest.attempt_number < 3
      AND latest.next_attempt_at IS NOT NULL
      AND latest.next_attempt_at <= NOW()
      AND NOT EXISTS (
        SELECT 1 FROM public.alerts a
        WHERE a.agency_id = p_agency_id
          AND a.alert_type = ANY (v_done_alert_types)
          AND a.related_id = hc.id
      )
    ORDER BY latest.next_attempt_at
    LIMIT (v_max_per_run - v_first_sent)
  LOOP
    BEGIN
      v_link_path := public.mint_v1_assessment_link(v_cand.id);
      v_full_link := v_app_url || v_link_path;
      v_position_display := COALESCE(NULLIF(v_cand.position, ''), 'the role');

      v_role_phrase := CASE
        WHEN v_cand.position IS NOT NULL AND v_cand.position <> ''
          THEN 'the <strong>' || v_cand.position || '</strong> role'
        ELSE 'this role'
      END;

      v_subject := 'Reminder: assessment for ' || v_position_display || ' at Peter Story State Farm';

      v_html :=
        '<p>Hi ' || COALESCE(v_cand.first_name, 'there') || ',</p>' ||
        '<p>Just following up on the assessment for ' || v_role_phrase ||
          ' at Peter Story State Farm.</p>' ||
        '<p>If you are still interested, please take about 30 minutes to complete it. ' ||
          'Your link is still active:</p>' ||
        '<p><a href="' || v_full_link || '" style="display:inline-block;padding:12px 24px;' ||
          'background:#737A59;color:#ffffff;text-decoration:none;border-radius:6px;' ||
          'font-weight:600;">Open the assessment</a></p>' ||
        '<p style="color:#64748b;font-size:13px;">If the button does not work, paste this ' ||
          'link into your browser:<br><a href="' || v_full_link || '">' || v_full_link || '</a></p>' ||
        '<p>If you have decided not to pursue this role, just reply to this email and let me ' ||
          'know so I can update our records.</p>' ||
        '<p>&mdash; Peter Story<br>Peter Story State Farm</p>';

      v_pg_net_id := public.composio_send_email(p_agency_id, v_cand.email, v_subject, v_html);

      v_next_attempt := CASE
        WHEN v_cand.last_attempt + 1 >= 3 THEN NULL
        ELSE NOW() + INTERVAL '1 day'
      END;

      INSERT INTO public.assessment_invitations
        (agency_id, candidate_id, attempt_number, sent_at, pg_net_request_id, subject, outcome, next_attempt_at)
      VALUES
        (p_agency_id, v_cand.id, v_cand.last_attempt + 1, NOW(), v_pg_net_id, v_subject, 'sent', v_next_attempt);

      UPDATE public.hiring_candidates
      SET status = 'assessment_sent'
      WHERE id = v_cand.id AND status = 'applied';

      v_reminder_sent := v_reminder_sent + 1;
      v_reminded_ids := array_append(v_reminded_ids, v_cand.id);
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors + 1;
      v_error_details := v_error_details || jsonb_build_object(
        'stage', 'reminder',
        'candidate_id', v_cand.id,
        'last_attempt', v_cand.last_attempt,
        'error', SQLERRM
      );
    END;
  END LOOP;

  -- Step 3: Terminal state — no_response after attempt 3 + 24h grace
  WITH exhausted AS (
    SELECT DISTINCT ai.candidate_id
    FROM public.assessment_invitations ai
    WHERE ai.agency_id = p_agency_id
      AND ai.outcome = 'sent'
      AND ai.attempt_number = 3
      AND ai.sent_at < NOW() - INTERVAL '1 day'
      AND NOT EXISTS (
        SELECT 1 FROM public.alerts a
        WHERE a.agency_id = p_agency_id
          AND a.alert_type = ANY (v_done_alert_types)
          AND a.related_id = ai.candidate_id
      )
  ),
  updated AS (
    UPDATE public.assessment_invitations ai
    SET outcome = 'no_response', updated_at = NOW()
    WHERE ai.agency_id = p_agency_id
      AND ai.outcome = 'sent'
      AND ai.candidate_id IN (SELECT candidate_id FROM exhausted)
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_no_response_swept FROM updated;

  v_records_processed := v_first_sent + v_reminder_sent;
  v_output_summary := v_first_sent || ' invite(s) sent, ' || v_reminder_sent || ' reminder(s) sent, ' ||
    v_resume_score_gated || ' resume-gated, ' || v_errors || ' error(s)' ||
    CASE WHEN v_completed_swept + v_declined_swept + v_exited_swept + v_no_response_swept > 0
      THEN ' (swept: ' || v_completed_swept || ' completed, ' || v_declined_swept || ' declined, ' ||
           v_exited_swept || ' exited, ' || v_no_response_swept || ' no-response)'
      ELSE ''
    END;

  RETURN jsonb_build_object(
    'first_sent', v_first_sent,
    'reminders_sent', v_reminder_sent,
    'resume_score_gated', v_resume_score_gated,
    'completed_swept', v_completed_swept,
    'declined_swept', v_declined_swept,
    'exited_swept', v_exited_swept,
    'no_response_swept', v_no_response_swept,
    'errors', v_errors,
    'error_details', v_error_details,
    'sent_candidate_ids', to_jsonb(v_sent_ids),
    'reminded_candidate_ids', to_jsonb(v_reminded_ids),
    'ran_at', NOW(),
    'records_processed', v_records_processed,
    'output_summary', v_output_summary
  );
END;
$function$;
