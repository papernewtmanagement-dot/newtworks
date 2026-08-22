
-- Peter directive 2026-08-14: 3+ delivery-delay notices for the same address with no
-- successful send is now treated as a bad-address signal, same as a hard bounce.
-- A single delay stays informational (Gmail retry, not a real problem).

ALTER TABLE public.assessment_invite_bounces
  ADD COLUMN IF NOT EXISTS notice_type text NOT NULL DEFAULT 'failure';

ALTER TABLE public.assessment_invite_bounces
  DROP CONSTRAINT IF EXISTS chk_assessment_invite_bounces_notice_type;
ALTER TABLE public.assessment_invite_bounces
  ADD CONSTRAINT chk_assessment_invite_bounces_notice_type CHECK (notice_type IN ('failure','delay'));

ALTER TABLE public.assessment_invite_bounces
  ADD COLUMN IF NOT EXISTS delay_escalated boolean NOT NULL DEFAULT false;

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
  v_delay_count    int;
  v_already_escalated boolean;
  v_context_note   text := '';
BEGIN
  -- Delay notices: a single one is normal Gmail retry behavior, not a bad address.
  -- Only act once the SAME address has racked up 3 delay notices with no successful
  -- send in between (Peter directive 2026-08-14). Hard failures (notice_type='failure')
  -- skip straight past this block, unchanged from before.
  IF NEW.notice_type = 'delay' THEN
    SELECT count(*) INTO v_delay_count
      FROM public.assessment_invite_bounces
     WHERE agency_id = NEW.agency_id
       AND notice_type = 'delay'
       AND lower(bounced_email) = lower(NEW.bounced_email);

    SELECT EXISTS (
      SELECT 1 FROM public.assessment_invite_bounces
       WHERE agency_id = NEW.agency_id
         AND notice_type = 'delay'
         AND lower(bounced_email) = lower(NEW.bounced_email)
         AND delay_escalated = true
    ) INTO v_already_escalated;

    IF v_delay_count < 3 OR v_already_escalated THEN
      -- Under threshold, or already escalated once for this address: just resolve
      -- the candidate for visibility, take no action, don't re-alert.
      SELECT id INTO v_candidate_id
        FROM public.hiring_candidates
       WHERE agency_id = NEW.agency_id AND lower(email) = lower(NEW.bounced_email)
       ORDER BY created_at DESC LIMIT 1;

      IF v_candidate_id IS NOT NULL THEN
        UPDATE public.assessment_invite_bounces
        SET candidate_id = v_candidate_id, matched = true
        WHERE id = NEW.id;
      END IF;

      RETURN NEW;
    END IF;

    UPDATE public.assessment_invite_bounces SET delay_escalated = true WHERE id = NEW.id;
    v_context_note := 'after 3 delivery-delay notices with no successful send (no hard bounce ever arrived) -- ';
  END IF;

  -- Shared workflow below: runs immediately for hard failures, and now also runs
  -- for a delay notice that just crossed the 3-strike threshold above.
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
      v_context_note || coalesce(v_candidate_name, 'A candidate') || ' already has status "' || v_status || '" -- no change made.',
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
      v_context_note || coalesce(v_candidate_name, 'A candidate') || ' declined (bounced_undeliverable) after ' || NEW.bounced_email ||
        ' could not be delivered to. No resume text survives for this candidate, so the address could not be checked either way -- email_uncertain set true.',
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
      v_context_note || coalesce(v_candidate_name, 'A candidate') || ' declined (bounced_undeliverable). Resume shows ' || NEW.bounced_email ||
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
      v_context_note || coalesce(v_candidate_name, 'A candidate') || ' -- mailed ' || NEW.bounced_email || ' could not be delivered to. Resume text exists but does not contain that address, ' ||
        'and no plausible alternate personal address was found in it either -- could be a contact section the extraction dropped rather than a wrong address. Check by hand before declining.',
      'hiring', v_candidate_id, false, false, now()
    );
    RETURN NEW;

  ELSIF array_length(v_alt_candidates, 1) > 1 THEN
    INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, related_id, is_read, is_resolved, created_at)
    VALUES (
      NEW.agency_id, 'candidate_bounce_multiple_alt_emails', 'warning',
      'Bounce: resume shows more than one possible address -- pick which one',
      v_context_note || coalesce(v_candidate_name, 'A candidate') || ' -- mailed ' || NEW.bounced_email || ' could not be delivered to. Resume shows more than one plausible address (' ||
        array_to_string(v_alt_candidates, ', ') || '), so none was applied automatically. Pick the right one and update hiring_candidates.email -- it will re-send on the next cycle.',
      'hiring', v_candidate_id, false, false, now()
    );
    RETURN NEW;

  ELSE
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
        v_context_note || coalesce(v_candidate_name, 'A candidate') || ' -- mailed ' || NEW.bounced_email || ' could not be delivered to. Resume showed exactly one alternate address, ' ||
          v_alt_email || ', which looked like a real personal address, not a company or generic one. Corrected hiring_candidates.email -- it will go out again on the next send cycle.',
        'hiring', v_candidate_id, false, false, now()
      );
    ELSE
      INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, related_id, is_read, is_resolved, created_at)
      VALUES (
        NEW.agency_id, 'candidate_bounce_email_corrected_manual_resend', 'warning',
        'Bounce: email auto-corrected, but all 3 attempts are used -- resend by hand',
        v_context_note || coalesce(v_candidate_name, 'A candidate') || ' -- mailed ' || NEW.bounced_email || ' could not be delivered to, on the 3rd and final attempt. Resume showed exactly ' ||
          'one alternate address, ' || v_alt_email || '. Corrected hiring_candidates.email, but the send pipeline is capped at 3 attempts and will not queue a 4th automatically -- send manually if still wanted.',
        'hiring', v_candidate_id, false, false, now()
      );
    END IF;

    RETURN NEW;
  END IF;
END;
$function$;

