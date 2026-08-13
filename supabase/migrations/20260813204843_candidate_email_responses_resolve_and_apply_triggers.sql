-- =====================================================================
-- candidate_email_responses: resolve the candidate, then apply the workflow
-- =====================================================================
-- The generic automation-runner has no per-recipe post-write hook, and Groq
-- cannot produce a hiring_candidates UUID. So candidate resolution and the
-- documented status side-effects live in the database, next to the data,
-- where every writer gets them -- runner, hand insert, or backfill.
--
-- WHY THE SPLIT ACROSS TWO TRIGGERS. The runner writes through PostgREST
-- upsert with ignoreDuplicates, i.e. ON CONFLICT DO NOTHING. A BEFORE INSERT
-- trigger fires even when the row is then discarded by the conflict clause;
-- cross-table writes made there would stick with no row to show for them,
-- and would re-fire on every duplicate tick. AFTER INSERT fires only when a
-- row was genuinely inserted. So: BEFORE normalizes columns on NEW only,
-- AFTER performs side-effects.
--
-- BOUNCES ARE DELIBERATELY NOT HANDLED HERE. The existing "Detect Assessment
-- Invite Bounces" recipe already owns delivery failures end to end and was
-- verified against a real delay notice on 2026-08-13 -- DaNasha Williams' 8/13
-- "delayed" notice correctly produced no bounce row, because that recipe's
-- prompt is written to take Failure only. A second, weaker bounce classifier
-- here would risk pulling healthy candidates out of the invite pool over a
-- temporary delay. A bounced_undeliverable row arriving on this table is
-- therefore treated as an anomaly worth an alert, not an instruction to act.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.candidate_email_response_resolve()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_candidate_id uuid;
BEGIN
  -- Keep the two message-id columns in step whichever one the writer set.
  IF NEW.source_message_id IS NULL AND NEW.gmail_message_id IS NOT NULL THEN
    NEW.source_message_id := NEW.gmail_message_id;
  ELSIF NEW.gmail_message_id IS NULL AND NEW.source_message_id IS NOT NULL THEN
    NEW.gmail_message_id := NEW.source_message_id;
  END IF;

  IF NEW.received_at IS NULL THEN
    NEW.received_at := now();
  END IF;

  -- Match the sender to a candidate. Deliberately conservative: exact
  -- lowercased email only. Relay senders (an Indeed relay address rather
  -- than the candidate's own) will NOT resolve, and that is correct -- the
  -- AFTER trigger raises an alert for a human match instead of guessing.
  IF NEW.hiring_candidate_id IS NULL AND NEW.from_email IS NOT NULL THEN
    SELECT hc.id
      INTO v_candidate_id
      FROM public.hiring_candidates hc
     WHERE hc.agency_id = NEW.agency_id
       AND lower(hc.email) = lower(btrim(NEW.from_email))
     ORDER BY hc.created_at DESC
     LIMIT 1;

    NEW.hiring_candidate_id := v_candidate_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_candidate_email_response_resolve
  ON public.candidate_email_responses;

CREATE TRIGGER trg_candidate_email_response_resolve
  BEFORE INSERT ON public.candidate_email_responses
  FOR EACH ROW
  EXECUTE FUNCTION public.candidate_email_response_resolve();


CREATE OR REPLACE FUNCTION public.candidate_email_response_apply()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_action text;
  v_name   text;
  v_status text;
BEGIN
  -- Unmatched sender: log it, alert for a human match, change nothing.
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
      UPDATE public.hiring_candidates
         SET status = 'declined',
             decline_reason = 'active_applicant'
       WHERE id = NEW.hiring_candidate_id;

      -- Stop the invite/reminder pipeline for any attempt still open.
      UPDATE public.assessment_invitations
         SET outcome = 'declined',
             next_attempt_at = NULL,
             updated_at = now()
       WHERE agency_id = NEW.agency_id
         AND candidate_id = NEW.hiring_candidate_id
         AND outcome = 'sent';

      v_action := 'status -> declined (active_applicant); open assessment invitations closed';
    ELSE
      v_action := format('no change -- candidate already at status "%s"', v_status);
    END IF;

  ELSIF NEW.response_type = 'bounced_undeliverable' THEN
    -- Not acted on here by design. See the migration header.
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
    -- interested_confirmation, interview_accepted,
    -- assessment_completed_notice, other: recorded, no field changes.
    v_action := 'logged only';
  END IF;

  UPDATE public.candidate_email_responses
     SET action_taken = v_action
   WHERE id = NEW.id;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_candidate_email_response_apply
  ON public.candidate_email_responses;

CREATE TRIGGER trg_candidate_email_response_apply
  AFTER INSERT ON public.candidate_email_responses
  FOR EACH ROW
  EXECUTE FUNCTION public.candidate_email_response_apply();
