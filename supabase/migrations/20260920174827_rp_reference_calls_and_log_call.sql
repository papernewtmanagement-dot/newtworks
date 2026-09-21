-- Item 3, the caller's own slice. Two functions the signed-in page calls.
--
-- A phone write-up is a row in hiring_candidate_references with source='call'.
-- It is the SAME table and the SAME scorer as an emailed reference, so nothing
-- here computes whether a reference is good — that is reference_is_positive,
-- reached through hiring_reference_progress.

CREATE UNIQUE INDEX IF NOT EXISTS hiring_candidate_references_one_per_contact
  ON public.hiring_candidate_references (contact_id)
  WHERE contact_id IS NOT NULL;

-- Save (or replace) the write-up for one reference contact.
CREATE OR REPLACE FUNCTION public.rp_reference_save_writeup(
  p_contact_id uuid, p_body text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a      record;
  rc     record;
  v_name text;
  v_by   text;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);

  SELECT c.*, hc.agency_id AS cand_agency,
         COALESCE(NULLIF(TRIM(COALESCE(hc.first_name,'') || ' ' || COALESCE(hc.last_name,'')), ''),
                  hc.candidate_name, 'Candidate') AS cand_name
  INTO rc
  FROM public.hiring_reference_contacts c
  JOIN public.hiring_candidates hc ON hc.id = c.candidate_id
  WHERE c.id = p_contact_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'reference contact not found' USING ERRCODE='22023'; END IF;
  IF rc.cand_agency <> a.agency_id THEN RAISE EXCEPTION 'wrong agency' USING ERRCODE='42501'; END IF;

  IF NOT a.is_admin AND NOT EXISTS (
       SELECT 1 FROM public.hiring_reference_callers(rc.candidate_id) k
       WHERE k.team_member_id = a.actor_id) THEN
    RAISE EXCEPTION 'these references are not assigned to you' USING ERRCODE='42501';
  END IF;

  IF btrim(COALESCE(p_body,'')) = '' THEN
    RAISE EXCEPTION 'the write-up is empty' USING ERRCODE='22023';
  END IF;

  SELECT NULLIF(TRIM(COALESCE(t.nickname, t.first_name) || ' ' || COALESCE(t.last_name,'')), '')
  INTO v_by FROM public.team t WHERE t.id = a.actor_id;

  v_name := rc.cand_name;

  INSERT INTO public.hiring_candidate_references
    (agency_id, candidate_id, contact_id, candidate_name_from_subject,
     reference_number, sender, received_at, subject, body, source)
  VALUES
    (rc.cand_agency, rc.candidate_id, rc.id, v_name,
     rc.slot_number,
     COALESCE(v_by, 'Phone call') || ' (phone call with ' || rc.contact_name || ')',
     now(),
     'Reference ' || rc.slot_number::text || ' - ' || v_name || ' (phone)',
     btrim(p_body), 'call')
  ON CONFLICT (contact_id) WHERE contact_id IS NOT NULL
  DO UPDATE SET body = EXCLUDED.body, received_at = now(), sender = EXCLUDED.sender;

  PERFORM public.onboarding_sync_reference_steps(rc.cand_agency);

  RETURN jsonb_build_object('ok', true, 'contact_id', rc.id);
END;
$function$;

-- Log one attempt at one reference contact.
CREATE OR REPLACE FUNCTION public.rp_reference_log_call(
  p_contact_id uuid, p_result text, p_notes text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a        record;
  rc       record;
  v_by     text;
  v_out    text;
  v_filed  boolean := false;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);

  IF p_result NOT IN ('no_answer','left_message','reached','declined','bad_number') THEN
    RAISE EXCEPTION 'unknown call result: %', p_result USING ERRCODE='22023';
  END IF;

  SELECT c.*, hc.agency_id AS cand_agency
  INTO rc
  FROM public.hiring_reference_contacts c
  JOIN public.hiring_candidates hc ON hc.id = c.candidate_id
  WHERE c.id = p_contact_id
  FOR UPDATE OF c;

  IF NOT FOUND THEN RAISE EXCEPTION 'reference contact not found' USING ERRCODE='22023'; END IF;
  IF rc.cand_agency <> a.agency_id THEN RAISE EXCEPTION 'wrong agency' USING ERRCODE='42501'; END IF;

  IF NOT a.is_admin AND NOT EXISTS (
       SELECT 1 FROM public.hiring_reference_callers(rc.candidate_id) k
       WHERE k.team_member_id = a.actor_id) THEN
    RAISE EXCEPTION 'these references are not assigned to you' USING ERRCODE='42501';
  END IF;

  SELECT NULLIF(TRIM(COALESCE(t.nickname, t.first_name) || ' ' || COALESCE(t.last_name,'')), '')
  INTO v_by FROM public.team t WHERE t.id = a.actor_id;

  v_out := CASE p_result
             WHEN 'reached'     THEN 'reached'
             WHEN 'declined'    THEN 'declined_to_speak'
             WHEN 'bad_number'  THEN 'unreachable'
             ELSE rc.outcome
           END;

  UPDATE public.hiring_reference_contacts
  SET attempts = COALESCE(attempts, '[]'::jsonb) || jsonb_build_object(
        'at', to_char(now() AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD"T"HH24:MI'),
        'by', COALESCE(v_by, 'someone'),
        'by_team_member_id', a.actor_id,
        'round', COALESCE(round, 1),
        'result', p_result),
      attempt_count   = attempt_count + 1,
      last_attempt_at = now(),
      reached_at      = CASE WHEN p_result = 'reached' THEN now() ELSE reached_at END,
      call_notes      = CASE WHEN p_result = 'reached' AND btrim(COALESCE(p_notes,'')) <> ''
                             THEN btrim(p_notes) ELSE call_notes END,
      outcome         = v_out,
      updated_at      = now()
  WHERE id = rc.id;

  IF p_result = 'reached' AND btrim(COALESCE(p_notes,'')) <> '' THEN
    PERFORM public.rp_reference_save_writeup(rc.id, p_notes);
    v_filed := true;

    INSERT INTO public.alerts
      (agency_id, alert_type, severity, title, message, module_reference, related_id)
    VALUES
      (rc.cand_agency, 'reference_received', 'info',
       'Reference ' || rc.slot_number::text || ' reached by phone',
       COALESCE(v_by, 'Someone') || ' spoke to ' || rc.contact_name
         || ' and filed the write-up. It still needs scoring before it counts.',
       'hiring', rc.candidate_id);
  END IF;

  RETURN jsonb_build_object('ok', true, 'outcome', v_out, 'writeup_filed', v_filed,
                            'progress', public.hiring_reference_progress(rc.candidate_id));
END;
$function$;

-- The caller's own list. An admin sees every candidate in reference check.
CREATE OR REPLACE FUNCTION public.rp_reference_calls()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a record; v_rows jsonb;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);

  SELECT COALESCE(jsonb_agg(x ORDER BY x.accepted_at DESC), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT hc.id AS candidate_id,
           COALESCE(NULLIF(TRIM(COALESCE(hc.first_name,'') || ' ' || COALESCE(hc.last_name,'')), ''),
                    hc.candidate_name, 'Candidate') AS candidate_name,
           hc.offer_job_title, hc.offer_start_date,
           hc.offer_accepted_at AS accepted_at,
           hc.reference_paused_at, hc.reference_paused_reason,
           hc.reference_help_email_sent_at, hc.reference_round2_opens_at,
           hc.reference_final_email_sent_at,
           (SELECT string_agg(COALESCE(k.caller_name,'—'), ', ')
              FROM public.hiring_reference_callers(hc.id) k) AS caller_label,
           public.hiring_reference_progress(hc.id) AS progress,
           (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                     'id', rc.id,
                     'slot', rc.slot_number,
                     'name', rc.contact_name,
                     'relationship', rc.relationship,
                     'company', rc.company,
                     'phone', rc.phone,
                     'email', rc.email,
                     'round', rc.round,
                     'attempt_count', rc.attempt_count,
                     'attempts', COALESCE(rc.attempts, '[]'::jsonb),
                     'last_attempt_at', rc.last_attempt_at,
                     'reached_at', rc.reached_at,
                     'outcome', rc.outcome,
                     'writeup', wr.body_text,
                     'scored', wr.reference_analysis IS NOT NULL,
                     'positive', CASE WHEN wr.reference_analysis IS NULL THEN NULL
                                      ELSE public.reference_is_positive(wr.reference_analysis) END
                   ) ORDER BY rc.slot_number), '[]'::jsonb)
              FROM public.hiring_reference_contacts rc
              LEFT JOIN public.hiring_candidate_references wr ON wr.contact_id = rc.id
             WHERE rc.candidate_id = hc.id) AS contacts
    FROM public.hiring_candidates hc
    WHERE hc.agency_id = a.agency_id
      AND EXISTS (SELECT 1 FROM public.hiring_reference_contacts rc WHERE rc.candidate_id = hc.id)
      AND (a.is_admin OR EXISTS (
            SELECT 1 FROM public.hiring_reference_callers(hc.id) k
            WHERE k.team_member_id = a.actor_id))
  ) x;

  RETURN jsonb_build_object('ok', true, 'is_admin', a.is_admin, 'rows', v_rows);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rp_reference_calls() TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_reference_log_call(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_reference_save_writeup(uuid, text) TO authenticated;
