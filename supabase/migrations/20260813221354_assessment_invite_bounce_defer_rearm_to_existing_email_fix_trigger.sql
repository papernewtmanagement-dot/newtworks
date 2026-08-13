-- =====================================================================
-- CORRECTION: remove the redundant re-arm UPDATE from the auto-correct
-- branch. trg_resume_bounced_invitation_on_email_fix (AFTER UPDATE OF
-- email ON hiring_candidates) was ALREADY LIVE and already does exactly
-- this -- unconditionally flips any outcome='bounced' row for that
-- candidate back to outcome='sent', next_attempt_at=now() the instant
-- hiring_candidates.email changes. It fires as soon as this function's
-- own UPDATE of hiring_candidates.email commits, which is BEFORE this
-- function's own re-arm UPDATE ran -- so the two were racing to do the
-- same write, and the existing trigger does not know about (or respect)
-- the 3-attempt cap the way this function tried to.
--
-- Found by testing, not by inspection: the attempt-cap-reached test case
-- was supposed to leave the invitation at outcome='bounced' since this
-- function's own guard correctly took the "manual resend" branch and
-- skipped its UPDATE -- but the row still ended up outcome='sent' anyway,
-- because the OTHER trigger did it regardless, the moment the email
-- UPDATE above it ran. Same mistake pattern as earlier this session
-- (assessment_invite_bounce_fold_into_existing_handler): built new logic
-- without checking for a live mechanism already doing the same thing.
--
-- NET EFFECT is harmless either way -- send_v1_assessment_invitations'
-- own reminder loop requires attempt_number < 3 regardless of outcome,
-- so an attempt-3 row flipped to 'sent' by the existing trigger still
-- never actually gets picked up and resent. But this function should not
-- claim credit for a re-arm it isn't actually the one performing, and
-- should not run a second, cap-aware UPDATE beside a first, cap-blind one
-- that already won the race. Removed. The alert wording is kept (still
-- honest: cap reached still means "won't actually resend automatically"
-- regardless of which trigger set the outcome column).
-- =====================================================================

CREATE OR REPLACE FUNCTION public.handle_assessment_invite_bounce()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_candidate_id   uuid;
  v_candidate_name text;
  v_status         text;
  v_resume         text;
  v_resume_found   boolean;
  v_all_matches    text[];
  v_alt_candidates text[];
  v_alt_email      text;
  v_latest_attempt int;
BEGIN
  SELECT id, coalesce(candidate_name, trim(concat_ws(' ', first_name, last_name))),
         status, resume_extracted_text
    INTO v_candidate_id, v_candidate_name, v_status, v_resume
  FROM public.hiring_candidates
  WHERE agency_id = NEW.agency_id
    AND lower(email) = lower(NEW.bounced_email)
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_candidate_id IS NULL THEN
    RETURN NEW;
  END IF;

  UPDATE public.assessment_invite_bounces
  SET candidate_id = v_candidate_id, matched = true
  WHERE id = NEW.id;

  -- Stop the reminder chain cold. Unchanged.
  UPDATE public.assessment_invitations
  SET outcome = 'bounced', next_attempt_at = NULL, updated_at = now()
  WHERE candidate_id = v_candidate_id
    AND agency_id = NEW.agency_id
    AND outcome = 'sent';

  IF v_status IS NOT NULL AND v_status IN ('declined','hired','former') THEN
    INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, related_id, is_read, is_resolved, created_at)
    VALUES (
      NEW.agency_id, 'candidate_bounce_no_change', 'info',
      'Bounce logged, candidate already at a settled status',
      coalesce(v_candidate_name, 'A candidate') || ' already has status "' || v_status || '" -- no change made.',
      'hiring', v_candidate_id, false, false, now()
    );
    RETURN NEW;
  END IF;

  v_resume_found := (v_resume IS NOT NULL AND btrim(v_resume) <> '');

  IF NOT v_resume_found THEN
    UPDATE public.hiring_candidates
       SET status = 'declined', decline_reason = 'bounced_undeliverable', email_uncertain = true
     WHERE id = v_candidate_id;

    INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, related_id, is_read, is_resolved, created_at)
    VALUES (
      NEW.agency_id, 'candidate_bounce_declined_no_resume', 'info',
      'Candidate declined on bounce -- no resume text to verify against',
      coalesce(v_candidate_name, 'A candidate') || ' declined (bounced_undeliverable) after ' || NEW.bounced_email ||
        ' bounced. No resume text survives for this candidate, so the address could not be checked either way -- email_uncertain set true.',
      'hiring', v_candidate_id, false, false, now()
    );
    RETURN NEW;
  END IF;

  IF v_resume ILIKE ('%' || NEW.bounced_email || '%') THEN
    UPDATE public.hiring_candidates
       SET status = 'declined', decline_reason = 'bounced_undeliverable'
     WHERE id = v_candidate_id;

    INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, related_id, is_read, is_resolved, created_at)
    VALUES (
      NEW.agency_id, 'candidate_bounce_declined_confirmed', 'info',
      'Candidate declined on bounce -- resume confirms the address was correct',
      coalesce(v_candidate_name, 'A candidate') || ' declined (bounced_undeliverable). Resume shows ' || NEW.bounced_email ||
        ' verbatim, matching what was mailed -- extraction was correct, the mailbox is dead.',
      'hiring', v_candidate_id, false, false, now()
    );
    RETURN NEW;
  END IF;

  -- CASE 3: resume shows a different address (or none plausible).
  SELECT array_agg(DISTINCT m[1])
    INTO v_all_matches
    FROM regexp_matches(v_resume, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', 'g') AS m;

  SELECT array_agg(x)
    INTO v_alt_candidates
    FROM unnest(v_all_matches) AS x
   WHERE lower(x) <> lower(NEW.bounced_email)
     AND lower(x) !~ '^(info|hr|careers|jobs|noreply|no-reply|support|contact|admin|recruiting|talent|hiring|apply|applications)@';

  IF v_alt_candidates IS NULL OR array_length(v_alt_candidates, 1) IS NULL THEN
    INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, related_id, is_read, is_resolved, created_at)
    VALUES (
      NEW.agency_id, 'candidate_bounce_unverifiable', 'warning',
      'Bounce: resume text present but does not show the mailed address',
      coalesce(v_candidate_name, 'A candidate') || ' -- mailed ' || NEW.bounced_email || ' bounced. Resume text exists but does not contain that address, ' ||
        'and no plausible alternate personal address was found in it either -- could be a contact section the extraction dropped rather than a wrong address. Check by hand before declining.',
      'hiring', v_candidate_id, false, false, now()
    );
    RETURN NEW;

  ELSIF array_length(v_alt_candidates, 1) > 1 THEN
    INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, related_id, is_read, is_resolved, created_at)
    VALUES (
      NEW.agency_id, 'candidate_bounce_multiple_alt_emails', 'warning',
      'Bounce: resume shows more than one possible address -- pick which one',
      coalesce(v_candidate_name, 'A candidate') || ' -- mailed ' || NEW.bounced_email || ' bounced. Resume shows more than one plausible address (' ||
        array_to_string(v_alt_candidates, ', ') || '), so none was applied automatically. Pick the right one and update hiring_candidates.email -- it will re-send on the next cycle.',
      'hiring', v_candidate_id, false, false, now()
    );
    RETURN NEW;

  ELSE
    -- Exactly one plausible alternate. Auto-correct.
    --
    -- Correcting hiring_candidates.email here is enough on its own --
    -- trg_resume_bounced_invitation_on_email_fix (pre-existing, live)
    -- fires on this exact UPDATE and flips the bounced invitation row
    -- back to outcome='sent' automatically. Do NOT duplicate that write
    -- here. v_latest_attempt is read only to word the alert honestly:
    -- send_v1_assessment_invitations' reminder loop still requires
    -- attempt_number < 3 regardless of outcome, so a 3rd-attempt bounce
    -- will not actually go back out even once re-armed.
    v_alt_email := v_alt_candidates[1];

    SELECT MAX(attempt_number) INTO v_latest_attempt
      FROM public.assessment_invitations
     WHERE candidate_id = v_candidate_id AND agency_id = NEW.agency_id;

    UPDATE public.hiring_candidates
       SET email = v_alt_email, email_uncertain = false
     WHERE id = v_candidate_id;

    IF v_latest_attempt IS NOT NULL AND v_latest_attempt < 3 THEN
      INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, related_id, is_read, is_resolved, created_at)
      VALUES (
        NEW.agency_id, 'candidate_bounce_email_corrected', 'info',
        'Bounce: email auto-corrected from resume, resend queued',
        coalesce(v_candidate_name, 'A candidate') || ' -- mailed ' || NEW.bounced_email || ' bounced. Resume showed exactly one alternate address, ' ||
          v_alt_email || ', which looked like a real personal address, not a company or generic one. Corrected hiring_candidates.email -- it will go out again on the next send cycle.',
        'hiring', v_candidate_id, false, false, now()
      );
    ELSE
      INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, related_id, is_read, is_resolved, created_at)
      VALUES (
        NEW.agency_id, 'candidate_bounce_email_corrected_manual_resend', 'warning',
        'Bounce: email auto-corrected, but all 3 attempts are used -- resend by hand',
        coalesce(v_candidate_name, 'A candidate') || ' -- mailed ' || NEW.bounced_email || ' bounced on the 3rd and final attempt. Resume showed exactly ' ||
          'one alternate address, ' || v_alt_email || '. Corrected hiring_candidates.email, but the send pipeline is capped at 3 attempts and will not queue a 4th automatically -- send manually if still wanted.',
        'hiring', v_candidate_id, false, false, now()
      );
    END IF;

    RETURN NEW;
  END IF;
END;
$function$;

DROP FUNCTION IF EXISTS public._debug_bounce_probe(uuid, uuid);
