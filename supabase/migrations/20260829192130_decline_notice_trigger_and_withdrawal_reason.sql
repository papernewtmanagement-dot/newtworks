-- 2026-08-29 (second pass, Peter directive) — decline notice becomes a trigger,
-- candidate withdrawal becomes its own reason, former team members never get one,
-- and the unconfirmed-address guard is removed.
--
-- 1. A trigger on hiring_candidates.status covers every decline path by
--    construction — all five write 'declined' to the same column — and it sends
--    at the moment of decline instead of up to 15 minutes later. The sweep drops
--    to once a day as a backstop only.
-- 2. 'candidate_withdrew' splits candidates who pulled out from candidates we
--    passed on. Both are declines; only one of them is our decision.
-- 3. former_team joins calibration_only on the never-send list.
-- 4. email_uncertain no longer blocks a send. A wrong address is the applicant's
--    typo, not something to hold mail over.

ALTER TABLE public.hiring_candidates
  DROP CONSTRAINT IF EXISTS team_assessments_decline_reason_check;

ALTER TABLE public.hiring_candidates
  ADD CONSTRAINT team_assessments_decline_reason_check
  CHECK (
    decline_reason IS NULL
    OR decline_reason = ANY (ARRAY[
      'active_applicant'::text,
      'candidate_withdrew'::text,
      'offer_rescinded'::text,
      'calibration_only'::text,
      'former_team'::text,
      'assessment_score'::text,
      'resume_score'::text,
      'bounced_undeliverable'::text
    ])
  );

-- status_updated_at was only being stamped by two of the five decline paths, so
-- the Declined view showed stale dates and any date-bounded logic (including the
-- notice cutover) read the wrong moment. One trigger fixes the whole class.
-- Named to sort last so it runs after the BEFORE triggers that change status.
CREATE OR REPLACE FUNCTION public.stamp_status_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status THEN
    NEW.status_updated_at := NOW();
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_zz_stamp_status_updated_at ON public.hiring_candidates;
CREATE TRIGGER trg_zz_stamp_status_updated_at
  BEFORE INSERT OR UPDATE ON public.hiring_candidates
  FOR EACH ROW EXECUTE FUNCTION public.stamp_status_updated_at();

-- A candidate who writes in to pull out is not someone we declined.
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
       SET action_taken = 'logged only -- sender not matched to a candidate, alert raised'
     WHERE id = NEW.id;

    RETURN NULL;
  END IF;

  SELECT btrim(coalesce(hc.first_name,'') || ' ' || coalesce(hc.last_name,'')), hc.status
    INTO v_name, v_status
    FROM public.hiring_candidates hc
   WHERE hc.id = NEW.hiring_candidate_id;

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

-- Existing rows where a reply proves the candidate pulled out.
UPDATE public.hiring_candidates hc
   SET decline_reason = 'candidate_withdrew'
 WHERE hc.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND hc.status = 'declined'
   AND hc.decline_reason = 'active_applicant'
   AND EXISTS (
     SELECT 1 FROM public.candidate_email_responses r
      WHERE r.hiring_candidate_id = hc.id
        AND r.response_type = 'declining'
   );

-- ── The single send path ──────────────────────────────────────────────────
-- Every rule and every word of both letters lives here. The trigger and the
-- daily backstop both call it; neither one holds a copy.
CREATE OR REPLACE FUNCTION public.send_one_candidate_decline_notice(
  p_agency_id uuid, p_candidate_id uuid
)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cand        RECORD;
  v_cutover     timestamptz;
  v_notice_id   uuid;
  v_subject     text;
  v_html        text;
  v_role_phrase text;
  v_pg_net_id   bigint;
BEGIN
  SELECT setting_value::timestamptz INTO v_cutover
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'decline_notice_cutover_at';

  IF v_cutover IS NULL THEN RETURN false; END IF;

  SELECT hc.id, hc.first_name, hc.email, hc.position, hc.decline_reason,
         hc.status, hc.is_test_candidate, hc.status_updated_at
    INTO v_cand
  FROM public.hiring_candidates hc
  WHERE hc.id = p_candidate_id AND hc.agency_id = p_agency_id;

  IF NOT FOUND THEN RETURN false; END IF;
  IF v_cand.status IS DISTINCT FROM 'declined' THEN RETURN false; END IF;
  IF v_cand.is_test_candidate IS TRUE THEN RETURN false; END IF;
  IF v_cand.email IS NULL OR v_cand.email = '' THEN RETURN false; END IF;
  IF COALESCE(v_cand.status_updated_at, NOW()) < v_cutover THEN RETURN false; END IF;

  -- calibration_only: paper-only record, nobody applied, nobody to write to.
  -- former_team: a past employee, not an applicant — telling them we are going
  --   with other candidates would be false on its face.
  -- bounced_undeliverable: the mailbox already hard-bounced. The letter cannot
  --   land, and the failure notice would come straight back into the inbox the
  --   bounce recipe reads.
  IF COALESCE(v_cand.decline_reason, '') = ANY (ARRAY[
       'calibration_only', 'former_team', 'bounced_undeliverable'
     ]) THEN
    RETURN false;
  END IF;

  -- Claim the slot first. The unique index on candidate_id makes this the lock:
  -- if the row is already there, someone already sent, and we stop here.
  INSERT INTO public.candidate_decline_notices
    (agency_id, candidate_id, decline_reason, subject)
  VALUES (p_agency_id, v_cand.id, v_cand.decline_reason, 'pending')
  ON CONFLICT (candidate_id) DO NOTHING
  RETURNING id INTO v_notice_id;

  IF v_notice_id IS NULL THEN RETURN false; END IF;

  v_role_phrase := CASE
    WHEN v_cand.position IS NOT NULL AND v_cand.position <> ''
      THEN 'the <strong>' || v_cand.position || '</strong> role'
    ELSE 'a role'
  END;

  IF v_cand.decline_reason = 'candidate_withdrew' THEN
    v_subject := 'Thanks for letting me know — Peter Story State Farm';
    v_html :=
      '<p>Hi ' || COALESCE(NULLIF(v_cand.first_name, ''), 'there') || ',</p>' ||
      '<p>Thanks for letting me know you are stepping out of the process for ' ||
        v_role_phrase || ' at Peter Story State Farm. I appreciate you closing ' ||
        'the loop instead of going quiet — that says something about you.</p>' ||
      '<p>Our openings change through the year. If the timing is better later on, ' ||
        'please apply again. I would be glad to take another look.</p>' ||
      '<p>Best of luck with whatever you have going on.</p>' ||
      '<p>&mdash; Peter Story<br>Peter Story State Farm</p>';
  ELSE
    v_subject := 'Update on your application — Peter Story State Farm';
    v_html :=
      '<p>Hi ' || COALESCE(NULLIF(v_cand.first_name, ''), 'there') || ',</p>' ||
      '<p>Thank you for applying for ' || v_role_phrase || ' at Peter Story State Farm, ' ||
        'and for the time you put into the process. I have decided to move forward with ' ||
        'other candidates for this position.</p>' ||
      '<p>That is a decision about fit for one particular seat at one particular moment, ' ||
        'and nothing more. I know how much work a job search takes, and I do not take it ' ||
        'lightly that you spent some of that effort here.</p>' ||
      '<p>The care you put into how you present yourself does show, and it will keep ' ||
        'showing. Our openings change through the year — if something opens that fits ' ||
        'you, please apply again. I would be glad to take another look.</p>' ||
      '<p>I wish you real success in whatever comes next.</p>' ||
      '<p>&mdash; Peter Story<br>Peter Story State Farm</p>';
  END IF;

  v_pg_net_id := public.composio_send_email(p_agency_id, v_cand.email, v_subject, v_html);

  UPDATE public.candidate_decline_notices
     SET subject = v_subject, pg_net_request_id = v_pg_net_id, sent_at = NOW()
   WHERE id = v_notice_id;

  RETURN true;
END;
$function$;

-- ── Trigger: send at the moment of decline ────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_candidate_decline_notice()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Never let a send problem block the decline itself from saving.
  BEGIN
    PERFORM public.send_one_candidate_decline_notice(NEW.agency_id, NEW.id);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO public.alerts (agency_id, alert_type, severity, title, message,
                               module_reference, related_id, is_read, is_resolved)
    VALUES (NEW.agency_id, 'decline_notice_send_failed', 'warning',
            'Decline notice could not be sent',
            'The decline saved, but the notice email failed: ' || SQLERRM ||
            ' The daily backstop sweep will retry.',
            'hiring', NEW.id, false, false);
  END;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_send_candidate_decline_notice ON public.hiring_candidates;
CREATE TRIGGER trg_send_candidate_decline_notice
  AFTER INSERT OR UPDATE OF status ON public.hiring_candidates
  FOR EACH ROW
  WHEN (NEW.status = 'declined')
  EXECUTE FUNCTION public.trg_candidate_decline_notice();

-- ── Daily backstop ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.send_candidate_decline_notices(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sent            int := 0;
  v_errors          int := 0;
  v_skipped_no_addr int := 0;
  v_cutover         timestamptz;
  v_cand            RECORD;
  v_error_details   jsonb := '[]'::jsonb;
BEGIN
  SELECT setting_value::timestamptz INTO v_cutover
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'decline_notice_cutover_at';

  IF v_cutover IS NULL THEN
    RETURN jsonb_build_object(
      'error', 'decline_notice_cutover_at missing — refusing to send',
      'ran_at', NOW(), 'records_processed', 0,
      'output_summary', 'ERROR: settings.decline_notice_cutover_at missing — refusing to send');
  END IF;

  SELECT COUNT(*) INTO v_skipped_no_addr
  FROM public.hiring_candidates hc
  WHERE hc.agency_id = p_agency_id
    AND hc.status = 'declined'
    AND hc.is_test_candidate IS NOT TRUE
    AND hc.status_updated_at >= v_cutover
    AND (hc.email IS NULL OR hc.email = '')
    AND COALESCE(hc.decline_reason,'') <> ALL (ARRAY['calibration_only','former_team','bounced_undeliverable'])
    AND NOT EXISTS (SELECT 1 FROM public.candidate_decline_notices n WHERE n.candidate_id = hc.id);

  FOR v_cand IN
    SELECT hc.id
    FROM public.hiring_candidates hc
    WHERE hc.agency_id = p_agency_id
      AND hc.status = 'declined'
      AND hc.status_updated_at >= v_cutover
      AND NOT EXISTS (SELECT 1 FROM public.candidate_decline_notices n WHERE n.candidate_id = hc.id)
    ORDER BY hc.status_updated_at
  LOOP
    BEGIN
      IF public.send_one_candidate_decline_notice(p_agency_id, v_cand.id) THEN
        v_sent := v_sent + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors + 1;
      v_error_details := v_error_details || jsonb_build_object('candidate_id', v_cand.id, 'error', SQLERRM);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'sent', v_sent,
    'errors', v_errors,
    'error_details', v_error_details,
    'skipped_no_address', v_skipped_no_addr,
    'ran_at', NOW(),
    'records_processed', v_sent,
    'output_summary', v_sent || ' decline notice(s) caught by the daily backstop, ' ||
      v_errors || ' error(s)' ||
      CASE WHEN v_skipped_no_addr > 0
        THEN ' (' || v_skipped_no_addr || ' have no email address on file)' ELSE '' END
  );
END;
$function$;

UPDATE public.automation_recipes
   SET cron_expression = '0 8 * * *',
       recipe_description = 'Daily backstop for the decline-notice trigger. The trigger on hiring_candidates.status sends at the moment of decline; this catches anything it missed. Skips calibration records, former team members, dead addresses, and anyone already sent.'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND internal_handler = 'send_candidate_decline_notices';
