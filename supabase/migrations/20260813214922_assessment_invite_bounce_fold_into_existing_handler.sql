-- =====================================================================
-- CORRECTION to the prior two migrations in this session
-- (assessment_invite_bounces_resolve_and_apply_triggers). Those added a
-- second, competing resolve+apply pair without checking for what already
-- existed. trg_handle_assessment_invite_bounce / handle_assessment_invite_
-- bounce() was ALREADY LIVE and already resolves candidate_id + matched,
-- already stops the reminder chain (outcome='bounced'). The two prior
-- rows on this table (Jamya Chambers, Kevin Barron Vazquez) got their
-- candidate_id/matched from THIS trigger, not by hand as previously
-- believed and reported.
--
-- Fix: retire the redundant resolve+apply pair entirely and extend the
-- existing, proven function instead of running a second path beside it.
-- Two AFTER INSERT triggers on the same table also fire in an ordering
-- (alphabetical by trigger name) that would have made the new one run
-- BEFORE the old one had resolved anything -- a second, sharper bug on
-- top of the redundancy.
-- =====================================================================

DROP TRIGGER IF EXISTS trg_assessment_invite_bounce_apply ON public.assessment_invite_bounces;
DROP TRIGGER IF EXISTS trg_assessment_invite_bounce_resolve ON public.assessment_invite_bounces;
DROP FUNCTION IF EXISTS public.assessment_invite_bounce_apply();
DROP FUNCTION IF EXISTS public.assessment_invite_bounce_resolve();

-- =====================================================================
-- handle_assessment_invite_bounce(): candidate resolution and reminder-
-- chain stop are UNCHANGED from the live version. Only the final step
-- changes: instead of one generic "assessment_invite_bounced" alert,
-- apply Peter's directive (2026-08-13) -- re-check the resume, then
-- decline if the mailed address was correct.
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
  v_alt_email      text;
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
  -- address. Unchanged -- runs regardless of what happens below, including
  -- for candidates already at a settled status (harmless no-op there since
  -- a settled candidate has no outcome='sent' rows left to stop).
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

  -- CASE 1: no resume text survives to check against. Cannot verify either
  -- way -- decline anyway (established 2026-08-12 on Kevin Barron Vazquez),
  -- but flag email_uncertain and say so, rather than implying the address
  -- was confirmed.
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
  -- Not an automatic decline and not an automatic email rewrite -- surface
  -- a suggested alternate if one is findable, and let a human decide.
  SELECT (regexp_matches(v_resume, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', 'g'))[1]
    INTO v_alt_email
   LIMIT 1;

  IF v_alt_email IS NOT NULL THEN
    INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, related_id, is_read, is_resolved, created_at)
    VALUES (
      NEW.agency_id, 'candidate_bounce_alt_email_found', 'warning',
      'Bounce: resume shows a different email address -- verify before deciding',
      coalesce(v_candidate_name, 'A candidate') || ' -- mailed ' || NEW.bounced_email || ' bounced, but the resume shows ' || v_alt_email ||
        ' instead. Possible bad extraction. Check by hand: if ' || v_alt_email ||
        ' is correct, update hiring_candidates.email and re-send the invite; if it is not, decline (bounced_undeliverable).',
      'hiring', v_candidate_id, false, false, now()
    );
  ELSE
    INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, related_id, is_read, is_resolved, created_at)
    VALUES (
      NEW.agency_id, 'candidate_bounce_unverifiable', 'warning',
      'Bounce: resume text present but does not show the mailed address',
      coalesce(v_candidate_name, 'A candidate') || ' -- mailed ' || NEW.bounced_email || ' bounced. Resume text exists but does not contain that address, ' ||
        'and no alternate email address was found in it either -- could be a contact section the extraction dropped rather than a wrong address. Check by hand before declining.',
      'hiring', v_candidate_id, false, false, now()
    );
  END IF;

  RETURN NEW;
END;
$function$;

-- Reassert the trigger wiring explicitly (idempotent -- function replaced
-- in place above, this just guarantees it's still attached the same way).
DROP TRIGGER IF EXISTS trg_handle_assessment_invite_bounce ON public.assessment_invite_bounces;
CREATE TRIGGER trg_handle_assessment_invite_bounce
  AFTER INSERT ON public.assessment_invite_bounces
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_assessment_invite_bounce();
