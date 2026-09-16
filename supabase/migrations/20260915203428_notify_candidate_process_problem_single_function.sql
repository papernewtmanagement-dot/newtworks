-- One function owns the "candidate is stuck" notice: builds the message, sends
-- the Telegram DM, raises the alert. The reply trigger calls it, and so does any
-- backfill of replies that were misclassified before process_problem existed.
-- Nothing else builds this message.
CREATE OR REPLACE FUNCTION public.notify_candidate_process_problem(p_response_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  r        candidate_email_responses;
  v_name   text;
  v_status text;
  v_who    text;
  v_sent   boolean := false;
BEGIN
  SELECT * INTO r FROM public.candidate_email_responses WHERE id = p_response_id;
  IF r.id IS NULL THEN
    RETURN jsonb_build_object('sent', false, 'error', 'no such response row');
  END IF;

  IF r.hiring_candidate_id IS NOT NULL THEN
    SELECT btrim(coalesce(hc.first_name,'') || ' ' || coalesce(hc.last_name,'')), hc.status
      INTO v_name, v_status
      FROM public.hiring_candidates hc
     WHERE hc.id = r.hiring_candidate_id;
  END IF;

  v_who := coalesce(nullif(v_name,''), coalesce(r.from_email, 'unknown sender'));

  BEGIN
    PERFORM public.telegram_send(
      'peter_dm',
      'Hiring problem reported' || E'\n\n' ||
      v_who || coalesce(' (' || v_status || ')', '') || E'\n' ||
      coalesce(r.from_email, '') || E'\n\n' ||
      '"' || left(coalesce(r.body_excerpt, '(no message text)'), 400) || '"' || E'\n\n' ||
      'Subject: ' || coalesce(r.subject, '(none)'),
      r.agency_id
    );
    v_sent := true;
  EXCEPTION WHEN OTHERS THEN
    v_sent := false;
  END;

  INSERT INTO public.alerts (
    agency_id, alert_type, severity, title, message,
    module_reference, is_read, is_resolved
  ) VALUES (
    r.agency_id,
    'candidate_process_problem',
    'warning',
    'Candidate is stuck in the hiring process',
    format(
      '%s wrote in reporting a problem: "%s" (subject: %s, from: %s). They cannot move forward until someone helps. Response row id %s.',
      v_who,
      left(coalesce(r.body_excerpt, '(no message text)'), 400),
      coalesce(r.subject, 'no subject'),
      coalesce(r.from_email, 'unknown'),
      r.id
    ),
    'candidate_email_responses:' || r.id::text,
    false, false
  )
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object('sent', v_sent, 'who', v_who, 'response_id', r.id);
END;
$function$;

-- Trigger now delegates the notice instead of building it inline.
CREATE OR REPLACE FUNCTION public.candidate_email_response_apply()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_action text;
  v_name   text;
  v_status text;
BEGIN
  IF NEW.hiring_candidate_id IS NOT NULL THEN
    SELECT btrim(coalesce(hc.first_name,'') || ' ' || coalesce(hc.last_name,'')), hc.status
      INTO v_name, v_status
      FROM public.hiring_candidates hc
     WHERE hc.id = NEW.hiring_candidate_id;
  END IF;

  -- Before the unmatched early-return on purpose: a problem report relayed by
  -- Indeed matches no candidate row, and that is exactly the case Peter still
  -- needs to hear about.
  IF NEW.response_type = 'process_problem' THEN
    PERFORM public.notify_candidate_process_problem(NEW.id);
  END IF;

  IF NEW.hiring_candidate_id IS NULL THEN
    INSERT INTO public.alerts (
      agency_id, alert_type, severity, title, message,
      module_reference, is_read, is_resolved
    ) VALUES (
      NEW.agency_id,
      'candidate_email_unmatched',
      'warning',
      'Candidate reply could not be matched to a candidate',
      format(
        'A candidate reply of type "%s" arrived from %s (subject: %s) but no hiring_candidates row has that email address. Match it by hand -- this is the expected shape for relay senders such as Indeed. Response row id %s.',
        NEW.response_type,
        coalesce(NEW.from_email, 'unknown sender'),
        coalesce(NEW.subject, 'no subject'),
        NEW.id
      ),
      'candidate_email_responses:' || NEW.id::text,
      false, false
    );

    UPDATE public.candidate_email_responses
       SET action_taken = CASE
             WHEN NEW.response_type = 'process_problem'
               THEN 'problem reported -- Telegram sent to Peter; sender not matched to a candidate, alert raised'
             ELSE 'logged only -- sender not matched to a candidate, alert raised'
           END
     WHERE id = NEW.id;

    RETURN NULL;
  END IF;

  IF NEW.response_type = 'declining' THEN
    -- Never reopen or overwrite a settled exit state.
    IF v_status IS NULL OR v_status NOT IN ('declined','hired','former') THEN
      -- Change 2026-08-29: 'candidate_withdrew', not 'active_applicant'. They
      -- pulled out; we did not pass on them. The two read identically on the
      -- column and the decline notice needs to tell them apart.
      UPDATE public.hiring_candidates
         SET status = 'declined',
             decline_reason = 'candidate_withdrew'
       WHERE id = NEW.hiring_candidate_id;

      UPDATE public.assessment_invitations
         SET outcome = 'declined',
             next_attempt_at = NULL,
             updated_at = now()
       WHERE agency_id = NEW.agency_id
         AND candidate_id = NEW.hiring_candidate_id
         AND outcome = 'sent';

      v_action := 'status -> declined (candidate_withdrew); open assessment invitations closed';
    ELSE
      v_action := format('no change -- candidate already at status "%s"', v_status);
    END IF;

  ELSIF NEW.response_type = 'process_problem' THEN
    -- No status change. They still want the job; something is in their way.
    v_action := 'problem reported -- Telegram sent to Peter, alert raised, no status change';

  ELSIF NEW.response_type = 'bounced_undeliverable' THEN
    INSERT INTO public.alerts (
      agency_id, alert_type, severity, title, message,
      module_reference, is_read, is_resolved
    ) VALUES (
      NEW.agency_id,
      'candidate_email_bounce_on_reply_table',
      'info',
      'Bounce landed on the candidate-reply table',
      format(
        'A bounced_undeliverable row was written for %s. Bounces are owned by the "Detect Assessment Invite Bounces" recipe, so nothing was changed on the candidate. Check whether it was a permanent failure or only a delay before touching the invite pool. Response row id %s.',
        coalesce(v_name, NEW.hiring_candidate_id::text),
        NEW.id
      ),
      'candidate_email_responses:' || NEW.id::text,
      false, false
    );
    v_action := 'logged only -- bounces handled by the bounce recipe, alert raised';

  ELSE
    v_action := 'logged only';
  END IF;

  UPDATE public.candidate_email_responses
     SET action_taken = v_action
   WHERE id = NEW.id;

  RETURN NULL;
END;
$function$;
