-- telegram_api_call returns {"ok": false, ...} instead of raising, so catching
-- exceptions alone reported a send as successful when Telegram had refused it.
-- Read the actual reply and report that.
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
  v_resp   jsonb;
  v_sent   boolean := false;
  v_err    text;
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
    v_resp := public.telegram_send(
      'peter_dm',
      'Hiring problem reported' || E'\n\n' ||
      v_who || coalesce(' (' || v_status || ')', '') || E'\n' ||
      coalesce(r.from_email, '') || E'\n\n' ||
      '"' || left(coalesce(r.body_excerpt, '(no message text)'), 400) || '"' || E'\n\n' ||
      'Subject: ' || coalesce(r.subject, '(none)'),
      r.agency_id
    );
    v_sent := coalesce((v_resp->>'ok')::boolean, false);
    IF NOT v_sent THEN
      v_err := coalesce(v_resp->>'description', v_resp->>'error', 'telegram refused the send');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_sent := false;
    v_err  := SQLERRM;
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
      '%s wrote in reporting a problem: "%s" (subject: %s, from: %s). They cannot move forward until someone helps.%s Response row id %s.',
      v_who,
      left(coalesce(r.body_excerpt, '(no message text)'), 400),
      coalesce(r.subject, 'no subject'),
      coalesce(r.from_email, 'unknown'),
      CASE WHEN v_sent THEN '' ELSE ' TELEGRAM DID NOT SEND: ' || coalesce(v_err,'unknown') || '.' END,
      r.id
    ),
    'candidate_email_responses:' || r.id::text,
    false, false
  )
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object('sent', v_sent, 'error', v_err, 'who', v_who, 'response_id', r.id);
END;
$function$;
