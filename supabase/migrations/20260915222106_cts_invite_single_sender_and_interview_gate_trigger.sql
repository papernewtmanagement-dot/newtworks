-- =========================================================================
-- CTS gate, piece two: one CTS sender, and the trigger that opens the
-- interview once a result lands.
-- =========================================================================
-- Under Peter's 2026-09-15 order the CTS link goes out the moment a candidate
-- passes the assessment verdict, while they are still in 'assessed', and the
-- interview invite waits for the result. Two things follow.
--
-- 1. The CTS email now has two callers: the scheduler (one candidate, right
--    after the verdict) and the hourly sweeper (anyone the scheduler missed).
--    So the letter moves into ONE per-candidate function and the sweeper
--    calls it in a loop. There is no second copy of the wording anywhere.
-- 2. Recording a result has to fire the interview invite. That is a trigger
--    on cts_completed_at, dispatching to the scheduler the same way
--    trg_dispatch_assessed_candidate already does.

-- -------------------------------------------------------------------------
-- send_cts_invite_to_candidate — owns the CTS letter. One candidate.
-- -------------------------------------------------------------------------
-- Deliberately does NOT check status. Whether this candidate has earned the
-- CTS is the caller's decision; this function owns the wording, the send and
-- the stamp. It does check the things that are true regardless of caller:
-- already sent, no email, test row, already decided.
CREATE OR REPLACE FUNCTION public.send_cts_invite_to_candidate(
  p_agency_id    uuid,
  p_candidate_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_url       text;
  v_cand      RECORD;
  v_subject   text;
  v_closing   text;
  v_html      text;
  v_pg_net_id bigint;
BEGIN
  SELECT setting_value INTO v_url
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'cts_sales_profile_register_url';

  IF v_url IS NULL OR btrim(v_url) = '' THEN
    RETURN jsonb_build_object('ok', false, 'action', 'skipped',
      'reason', 'cts_sales_profile_register_url setting is blank');
  END IF;

  SELECT hc.id, hc.first_name, hc.email, hc.position, hc.interview_scheduled_start,
         hc.cts_invite_sent_at, hc.is_test_candidate, hc.decision_at
  INTO v_cand
  FROM public.hiring_candidates hc
  WHERE hc.id = p_candidate_id AND hc.agency_id = p_agency_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'action', 'skipped', 'reason', 'candidate not found');
  END IF;
  IF v_cand.is_test_candidate IS TRUE THEN
    RETURN jsonb_build_object('ok', true, 'action', 'skipped', 'reason', 'test candidate');
  END IF;
  IF v_cand.cts_invite_sent_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'action', 'skipped', 'reason', 'already sent',
      'sent_at', v_cand.cts_invite_sent_at);
  END IF;
  IF v_cand.decision_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'action', 'skipped', 'reason', 'already decided');
  END IF;
  IF v_cand.email IS NULL OR v_cand.email = '' THEN
    RETURN jsonb_build_object('ok', false, 'action', 'skipped', 'reason', 'no email address');
  END IF;

  v_subject := 'Next step: sales profile assessment' ||
               CASE WHEN NULLIF(v_cand.position, '') IS NOT NULL
                    THEN ' for ' || v_cand.position ELSE '' END ||
               ' at Peter Story State Farm';

  -- Wording depends on where they are. Before the gate existed the CTS
  -- followed the interview booking; now it comes first for everyone new, so
  -- the default line says the interview waits on it.
  v_closing := CASE
    WHEN v_cand.interview_scheduled_start IS NOT NULL
     AND v_cand.interview_scheduled_start < NOW()
      THEN 'Please finish it in the next few days so I have it alongside your assessment results.'
    WHEN v_cand.interview_scheduled_start IS NOT NULL
      THEN 'Please finish it before your interview so we can talk through both sets of results together.'
    ELSE 'Once it is in, I will send you times to pick from for the interview.'
  END;

  v_html :=
    '<p>Hi ' || COALESCE(NULLIF(v_cand.first_name, ''), 'there') || ',</p>' ||
    '<p>Thanks for finishing the assessment. I appreciate the time you put in.</p>' ||
    '<p>There is one more step in the process. It is a short sales profile called the CTS. ' ||
      'It takes about 25 minutes and there is nothing to prepare. ' ||
      'Answer honestly with the first reaction that comes to mind. This will give you a ' ||
      'good understanding of whether this role will inspire you or stress you.</p>' ||
    '<p><a href="' || v_url || '" style="display:inline-block;padding:12px 24px;' ||
      'background:#737A59;color:#ffffff;text-decoration:none;border-radius:6px;' ||
      'font-weight:600;">Start the sales profile</a></p>' ||
    '<p style="color:#64748b;font-size:13px;">The link will have you register first, then it starts. ' ||
      'If the button does not work, paste this link into your browser:<br>' ||
      '<a href="' || v_url || '">' || v_url || '</a></p>' ||
    '<p>' || v_closing || '</p>' ||
    '<p>&mdash; Peter Story<br>Peter Story State Farm</p>';

  v_pg_net_id := public.composio_send_email(p_agency_id, v_cand.email, v_subject, v_html);

  UPDATE public.hiring_candidates
  SET cts_invite_sent_at = NOW(), cts_invite_pg_net_id = v_pg_net_id
  WHERE id = p_candidate_id;

  RETURN jsonb_build_object('ok', true, 'action', 'sent',
    'candidate_id', p_candidate_id, 'to', v_cand.email, 'pg_net_id', v_pg_net_id);
END;
$function$;

COMMENT ON FUNCTION public.send_cts_invite_to_candidate(uuid, uuid) IS
  'The only place the CTS Sales Profile letter is written. Callers decide eligibility; this owns the wording, the send and the cts_invite_sent_at stamp.';

-- -------------------------------------------------------------------------
-- send_cts_sales_profile_invites — now the safety net, not the main path.
-- -------------------------------------------------------------------------
-- The scheduler sends the CTS the moment the verdict clears. This hourly
-- sweep catches anyone it missed: an edge function that failed, a Gmail
-- outage, or a candidate whose email was fixed after the fact.
--
-- 'assessed' is now INCLUDED, which is the reverse of the old rule. The old
-- comment was right at the time: 'assessed' meant the verdict had not run, so
-- a would-be decline could have been sent a CTS. It is safe now because the
-- scheduler decides within seconds of the status landing, and an auto-decline
-- stamps decision_at. A row still sitting in 'assessed' an hour later with
-- decision_at null has therefore passed the verdict.
CREATE OR REPLACE FUNCTION public.send_cts_sales_profile_invites(
  p_agency_id uuid,
  p_recipe_id uuid,
  p_backfill  boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_live_since    timestamptz;
  v_max_per_run   int := 10;
  v_sent          int := 0;
  v_errors        int := 0;
  v_error_details jsonb := '[]'::jsonb;
  v_sent_ids      uuid[] := ARRAY[]::uuid[];
  v_cand          RECORD;
  v_res           jsonb;
BEGIN
  IF p_backfill THEN
    v_live_since := '-infinity'::timestamptz;
  ELSE
    SELECT created_at INTO v_live_since
    FROM public.automation_recipes WHERE id = p_recipe_id;
    IF v_live_since IS NULL THEN v_live_since := NOW(); END IF;
  END IF;

  FOR v_cand IN
    SELECT hc.id
    FROM public.hiring_candidates hc
    WHERE hc.agency_id = p_agency_id
      AND hc.is_test_candidate IS NOT TRUE
      AND hc.cts_invite_sent_at IS NULL
      AND hc.assessment_completed_at IS NOT NULL
      AND hc.assessment_completed_at >= v_live_since
      AND hc.assessment_completed_at <= NOW() - INTERVAL '1 hour'
      AND hc.status IN ('assessed', 'interview', 'meet_and_greet', 'offer', 'reference_check')
      AND hc.decision_at IS NULL
      AND hc.assessment_exit_gate IS NULL
      AND hc.email IS NOT NULL
      AND hc.email <> ''
    ORDER BY hc.assessment_completed_at
    LIMIT v_max_per_run
  LOOP
    BEGIN
      v_res := public.send_cts_invite_to_candidate(p_agency_id, v_cand.id);
      IF v_res->>'action' = 'sent' THEN
        v_sent := v_sent + 1;
        v_sent_ids := array_append(v_sent_ids, v_cand.id);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors + 1;
      v_error_details := v_error_details || jsonb_build_object(
        'candidate_id', v_cand.id, 'error', SQLERRM);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'sent', v_sent,
    'errors', v_errors,
    'error_details', v_error_details,
    'sent_candidate_ids', to_jsonb(v_sent_ids),
    'backfill', p_backfill,
    'ran_at', NOW(),
    'records_processed', v_sent,
    'output_summary', v_sent || ' CTS invite(s) sent, ' || v_errors || ' error(s)');
END;
$function$;

-- -------------------------------------------------------------------------
-- The gate: a recorded CTS result fires the interview invite.
-- -------------------------------------------------------------------------
-- Same shape as dispatch_assessed_candidate on purpose. pg_net queues the
-- request and sends it after this transaction commits, so the scheduler reads
-- a row that already carries the result.
CREATE OR REPLACE FUNCTION public.dispatch_cts_result_candidate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'net', 'pg_catalog'
AS $function$
DECLARE
  v_url    text;
  v_secret text;
BEGIN
  IF NEW.is_test_candidate IS TRUE THEN RETURN NULL; END IF;
  IF NEW.decision_at IS NOT NULL THEN RETURN NULL; END IF;
  -- Already holds a booking link: nothing to open.
  IF NEW.interview_invite_token IS NOT NULL THEN RETURN NULL; END IF;
  -- Only someone waiting at the gate. A result recorded on a candidate who is
  -- already past the interview stage is filing, not a trigger to invite them.
  IF NEW.status <> 'assessed' THEN RETURN NULL; END IF;

  SELECT setting_value INTO v_url
  FROM public.settings
  WHERE agency_id = NEW.agency_id AND setting_key = 'supabase_url';

  SELECT setting_value INTO v_secret
  FROM public.settings
  WHERE agency_id = NEW.agency_id AND setting_key = 'automation_runner_cron_secret';

  IF v_url IS NULL OR v_secret IS NULL THEN RETURN NULL; END IF;

  PERFORM net.http_post(
    url     := v_url || '/functions/v1/hiring-interview-scheduler',
    headers := public.edge_fn_headers(),
    body    := jsonb_build_object(
                 'mode',          'send_interview_invite',
                 'agency_id',     NEW.agency_id,
                 'shared_secret', v_secret,
                 'candidate_id',  NEW.id
               ),
    timeout_milliseconds := 120000
  );

  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_dispatch_cts_result ON public.hiring_candidates;
CREATE TRIGGER trg_dispatch_cts_result
AFTER UPDATE OF cts_completed_at ON public.hiring_candidates
FOR EACH ROW
WHEN (OLD.cts_completed_at IS NULL AND NEW.cts_completed_at IS NOT NULL)
EXECUTE FUNCTION public.dispatch_cts_result_candidate();

COMMENT ON FUNCTION public.dispatch_cts_result_candidate() IS
  'The CTS gate. Recording a result on a candidate still sitting in assessed fires the interview invite through hiring-interview-scheduler mode send_interview_invite.';
