-- =====================================================================
-- assessment_invite_bounces: auto-correct the email when exactly one
-- plausible alternate address is found, and re-arm the invite pipeline
-- =====================================================================
-- Peter directive 2026-08-13 (follow-up): when the resume shows a
-- different address than the one that bounced, if it looks clean, just
-- fix it and move on instead of alerting.
--
-- WHY "fixing the email" alone is not enough. send_v1_assessment_invitations
-- only sends through two paths: (a) attempt 1, gated on
-- NOT EXISTS (any assessment_invitations row for the candidate) -- a
-- bounced candidate already has one, so this path is closed forever; or
-- (b) a reminder, gated on the candidate's LATEST invitation row having
-- outcome='sent' AND next_attempt_at due. handle_assessment_invite_bounce
-- already flips that row to outcome='bounced', next_attempt_at=NULL
-- (unchanged, upstream of this migration) specifically to stop reminders
-- going to a dead address. So correcting hiring_candidates.email changes
-- nothing on its own -- the candidate is structurally unreachable by
-- either path until something re-opens eligibility. This migration does
-- that: it flips the LATEST invitation row back to outcome='sent' with
-- next_attempt_at=now(), so the next scheduled run of
-- send_v1_assessment_invitations treats it as a reminder that's come due
-- and mints a fresh link to the corrected address. The actual send still
-- happens through that existing, already-approved automation on its own
-- schedule -- nothing here sends an email directly.
--
-- ATTEMPT CAP. assessment_invitations_attempt_number_check limits attempts
-- to 1-3, same as send_v1_assessment_invitations' own reminder-loop
-- condition (attempt_number < 3). If the bounce was on attempt 3, there is
-- no attempt 4 to re-arm into -- the email still gets corrected, but the
-- alert says manual resend is needed rather than claiming one is queued.
--
-- SAFETY RAIL ON THE AUTO-CORRECT ITSELF: only proceeds when EXACTLY ONE
-- plausible alternate address survives after (a) excluding the bounced
-- address itself and (b) excluding generic/non-personal local parts
-- (info@, hr@, careers@, jobs@, noreply@, support@, contact@, admin@,
-- recruiting@, talent@, hiring@, apply@, applications@) -- a resume
-- listing a company or recruiter contact should not get mistaken for the
-- candidate's own address. Zero plausible matches or more than one still
-- falls back to alert-only, unchanged from the prior version of this
-- function.
--
-- SUPERSEDED same session by migration
-- assessment_invite_bounce_defer_rearm_to_existing_email_fix_trigger --
-- the re-arm UPDATE this version adds duplicates a pre-existing trigger
-- (trg_resume_bounced_invitation_on_email_fix) that already does this on
-- any hiring_candidates.email change. Kept in the mirror for an honest
-- ledger; do not treat this version as current.
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
    -- Not tied to a hiring candidate we know about (could be a bounce from
    -- some other outbound mail this account sends). Leave matched=false,
    -- no alert -- nothing actionable on the hiring side. Unchanged.
    RETURN NEW;
  END IF;

  UPDATE public.assessment_invite_bounces
  SET candidate_id = v_candidate_id, matched = true
  WHERE id = NEW.id;

  -- Stop the reminder chain cold. Do NOT let attempts 2/3 fire at a dead
  -- address. Unchanged -- runs regardless of what happens below.
  UPDATE public.assessment_invitations
  SET outcome = 'bounced', next_attempt_at = NULL, updated_at = now()
  WHERE candidate_id = v_candidate_id
    AND agency_id = NEW.agency_id
    AND outcome = 'sent';

  -- Never reopen or overwrite a settled exit state with the process below.
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

  -- CASE 1: no resume text survives to check against. Decline anyway
  -- (established 2026-08-12, Kevin Barron Vazquez), flag email_uncertain.
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

  -- CASE 2: resume text exists and contains the mailed address verbatim.
  -- Extraction was correct -- decline.
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

  -- CASE 3: resume text exists but does not contain the mailed address.
  -- Collect every distinct email-shaped string in the resume, drop the
  -- bounced address itself and any generic/non-personal address, then act
  -- on what's left.
  SELECT array_agg(DISTINCT m[1])
    INTO v_all_matches
    FROM regexp_matches(v_resume, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', 'g') AS m;

  SELECT array_agg(x)
    INTO v_alt_candidates
    FROM unnest(v_all_matches) AS x
   WHERE lower(x) <> lower(NEW.bounced_email)
     AND lower(x) !~ '^(info|hr|careers|jobs|noreply|no-reply|support|contact|admin|recruiting|talent|hiring|apply|applications)@';

  IF v_alt_candidates IS NULL OR array_length(v_alt_candidates, 1) IS NULL THEN
    -- No plausible alternate at all -- same as before, alert only.
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
    -- More than one plausible alternate -- ambiguous, needs a human pick.
    INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, related_id, is_read, is_resolved, created_at)
    VALUES (
      NEW.agency_id, 'candidate_bounce_multiple_alt_emails', 'warning',
      'Bounce: resume shows more than one possible address -- pick which one',
      coalesce(v_candidate_name, 'A candidate') || ' -- mailed ' || NEW.bounced_email || ' bounced. Resume shows more than one plausible address (' ||
        array_to_string(v_alt_candidates, ', ') || '), so none was applied automatically. Pick the right one, update hiring_candidates.email, and it will re-send on the next cycle.',
      'hiring', v_candidate_id, false, false, now()
    );
    RETURN NEW;

  ELSE
    -- Exactly one plausible alternate. Auto-correct.
    v_alt_email := v_alt_candidates[1];

    UPDATE public.hiring_candidates
       SET email = v_alt_email, email_uncertain = false
     WHERE id = v_candidate_id;

    SELECT MAX(attempt_number) INTO v_latest_attempt
      FROM public.assessment_invitations
     WHERE candidate_id = v_candidate_id AND agency_id = NEW.agency_id;

    IF v_latest_attempt IS NOT NULL AND v_latest_attempt < 3 THEN
      -- Re-arm: flip the latest (just-bounced) row back to 'sent' with a
      -- due next_attempt_at so send_v1_assessment_invitations' reminder
      -- loop treats it as due and sends a fresh link to the corrected
      -- address on its own next scheduled run.
      UPDATE public.assessment_invitations
         SET outcome = 'sent', next_attempt_at = now(), updated_at = now()
       WHERE candidate_id = v_candidate_id
         AND agency_id = NEW.agency_id
         AND attempt_number = v_latest_attempt;

      INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, related_id, is_read, is_resolved, created_at)
      VALUES (
        NEW.agency_id, 'candidate_bounce_email_corrected', 'info',
        'Bounce: email auto-corrected from resume, resend queued',
        coalesce(v_candidate_name, 'A candidate') || ' -- mailed ' || NEW.bounced_email || ' bounced. Resume showed exactly one alternate address, ' ||
          v_alt_email || ', which looked like a real personal address, not a company or generic one. Corrected hiring_candidates.email and queued it ' ||
          'to go out again on the next send cycle.',
        'hiring', v_candidate_id, false, false, now()
      );
    ELSE
      -- Attempt cap reached (3 of 3) -- corrected, but nothing left in the
      -- pipeline to resend it. Manual send needed.
      INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, related_id, is_read, is_resolved, created_at)
      VALUES (
        NEW.agency_id, 'candidate_bounce_email_corrected_manual_resend', 'warning',
        'Bounce: email auto-corrected, but all 3 attempts are used -- resend by hand',
        coalesce(v_candidate_name, 'A candidate') || ' -- mailed ' || NEW.bounced_email || ' bounced on the 3rd and final attempt. Resume showed exactly ' ||
          'one alternate address, ' || v_alt_email || '. Corrected hiring_candidates.email, but the automatic pipeline has no attempt left to queue -- send manually if still wanted.',
        'hiring', v_candidate_id, false, false, now()
      );
    END IF;

    RETURN NEW;
  END IF;
END;
$function$;
