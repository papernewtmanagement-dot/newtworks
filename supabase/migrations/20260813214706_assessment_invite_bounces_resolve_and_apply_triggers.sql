-- =====================================================================
-- assessment_invite_bounces: resolve the candidate, then apply the
-- resume-recheck-and-decline process
-- =====================================================================
-- GAP FOUND WHILE BUILDING THIS: candidate_id and matched are NOT
-- currently populated by anything. Neither a trigger nor a default exists
-- on this table. The two existing rows (Jamya Chambers, Kevin Barron
-- Vazquez) got their candidate_id/matched set by hand on 2026-08-12 --
-- the "Detect Assessment Invite Bounces" recipe's generic writeOutput()
-- only writes columns Groq's prompt actually returns (source_message_id,
-- bounced_email), and Groq cannot produce a hiring_candidates UUID. Every
-- bounce landing since has been sitting with candidate_id NULL until
-- looked at by hand. Fixed here as part of the same build, not spun off,
-- because the apply step below cannot run without a resolved candidate.
--
-- PROCESS THIS AUTOMATES (Peter directive, 2026-08-13): on a bounce,
-- re-check the resume. If the mailed address matches what the resume
-- actually shows -- or no resume text survives to check against -- the
-- extraction was not the problem, and the candidate is declined,
-- reason=bounced_undeliverable. That is the entire decision procedure;
-- there is no third outcome for those two cases.
--
-- The one case that stays a human decision: the resume shows a DIFFERENT
-- address than the one that bounced. That is not "wrong extraction" or
-- "right extraction" -- it is a specific, correctable data problem, and
-- auto-rewriting hiring_candidates.email off a regex match with no human
-- look would risk mailing the wrong person on a bad match. Alert only.
--
-- SUPERSEDED same session by migration
-- assessment_invite_bounce_fold_into_existing_handler -- this pair
-- duplicated a resolve step that was already live on
-- trg_handle_assessment_invite_bounce, and would have run BEFORE it on
-- INSERT (alphabetical trigger ordering). Kept in the mirror for an
-- honest ledger; do not treat this version as current. See the follow-up
-- migration for what is actually live.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.assessment_invite_bounce_resolve()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_candidate_id uuid;
BEGIN
  IF NEW.candidate_id IS NULL AND NEW.bounced_email IS NOT NULL THEN
    SELECT hc.id
      INTO v_candidate_id
      FROM public.hiring_candidates hc
     WHERE hc.agency_id = NEW.agency_id
       AND lower(hc.email) = lower(btrim(NEW.bounced_email))
     ORDER BY hc.created_at DESC
     LIMIT 1;

    NEW.candidate_id := v_candidate_id;
  END IF;

  NEW.matched := (NEW.candidate_id IS NOT NULL);

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_assessment_invite_bounce_resolve
  ON public.assessment_invite_bounces;

CREATE TRIGGER trg_assessment_invite_bounce_resolve
  BEFORE INSERT ON public.assessment_invite_bounces
  FOR EACH ROW
  EXECUTE FUNCTION public.assessment_invite_bounce_resolve();


CREATE OR REPLACE FUNCTION public.assessment_invite_bounce_apply()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_name          text;
  v_status        text;
  v_resume        text;
  v_resume_found  boolean;
  v_alt_email     text;
BEGIN
  -- Unmatched bounce: nothing to check a resume against yet. Alert for a
  -- human match, same shape as the candidate-reply table's unmatched case.
  IF NEW.candidate_id IS NULL THEN
    INSERT INTO public.alerts (
      agency_id, alert_type, severity, title, message,
      module_reference, is_read, is_resolved
    ) VALUES (
      NEW.agency_id,
      'candidate_bounce_unmatched',
      'warning',
      'Assessment invite bounce could not be matched to a candidate',
      format(
        'A bounce for %s could not be matched to any hiring_candidates row by email. Match it by hand. Bounce row id %s.',
        NEW.bounced_email, NEW.id
      ),
      'assessment_invite_bounces:' || NEW.id::text,
      false, false
    );
    RETURN NULL;
  END IF;

  SELECT btrim(coalesce(hc.first_name,'') || ' ' || coalesce(hc.last_name,'')),
         hc.status,
         hc.resume_extracted_text
    INTO v_name, v_status, v_resume
    FROM public.hiring_candidates hc
   WHERE hc.id = NEW.candidate_id;

  -- Never reopen or overwrite a settled exit state.
  IF v_status IS NOT NULL AND v_status IN ('declined','hired','former') THEN
    INSERT INTO public.alerts (
      agency_id, alert_type, severity, title, message,
      module_reference, is_read, is_resolved
    ) VALUES (
      NEW.agency_id,
      'candidate_bounce_no_change',
      'info',
      'Bounce logged, candidate already at a settled status',
      format('%s already has status "%s". Bounce row id %s -- no change made.',
        coalesce(v_name, NEW.candidate_id::text), v_status, NEW.id),
      'assessment_invite_bounces:' || NEW.id::text,
      false, false
    );
    RETURN NULL;
  END IF;

  v_resume_found := (v_resume IS NOT NULL AND btrim(v_resume) <> '');

  -- CASE 1: no resume text survives to check against. Cannot verify either
  -- way -- per the established rule (Kevin Barron Vazquez, 2026-08-12),
  -- decline anyway, but flag email_uncertain and say so in the alert
  -- rather than implying the address was confirmed.
  IF NOT v_resume_found THEN
    UPDATE public.hiring_candidates
       SET status = 'declined',
           decline_reason = 'bounced_undeliverable',
           email_uncertain = true
     WHERE id = NEW.candidate_id;

    UPDATE public.assessment_invitations
       SET outcome = 'declined', next_attempt_at = NULL, updated_at = now()
     WHERE agency_id = NEW.agency_id
       AND candidate_id = NEW.candidate_id
       AND outcome = 'sent';

    INSERT INTO public.alerts (
      agency_id, alert_type, severity, title, message,
      module_reference, is_read, is_resolved
    ) VALUES (
      NEW.agency_id,
      'candidate_bounce_declined_no_resume',
      'info',
      'Candidate declined on bounce -- no resume text to verify against',
      format(
        '%s declined (bounced_undeliverable) after %s bounced. No resume text survives for this candidate, so the address could not be checked either way -- email_uncertain set true. Bounce row id %s.',
        coalesce(v_name, NEW.candidate_id::text), NEW.bounced_email, NEW.id
      ),
      'assessment_invite_bounces:' || NEW.id::text,
      false, false
    );
    RETURN NULL;
  END IF;

  -- CASE 2: resume text exists and contains the mailed address verbatim.
  -- Extraction was correct -- decline.
  IF v_resume ILIKE ('%' || NEW.bounced_email || '%') THEN
    UPDATE public.hiring_candidates
       SET status = 'declined',
           decline_reason = 'bounced_undeliverable'
     WHERE id = NEW.candidate_id;

    UPDATE public.assessment_invitations
       SET outcome = 'declined', next_attempt_at = NULL, updated_at = now()
     WHERE agency_id = NEW.agency_id
       AND candidate_id = NEW.candidate_id
       AND outcome = 'sent';

    INSERT INTO public.alerts (
      agency_id, alert_type, severity, title, message,
      module_reference, is_read, is_resolved
    ) VALUES (
      NEW.agency_id,
      'candidate_bounce_declined_confirmed',
      'info',
      'Candidate declined on bounce -- resume confirms the address was correct',
      format(
        '%s declined (bounced_undeliverable). Resume shows %s verbatim, matching what was mailed -- extraction was correct, the mailbox is dead. Bounce row id %s.',
        coalesce(v_name, NEW.candidate_id::text), NEW.bounced_email, NEW.id
      ),
      'assessment_invite_bounces:' || NEW.id::text,
      false, false
    );
    RETURN NULL;
  END IF;

  -- CASE 3: resume text exists but does not contain the mailed address.
  -- Look for a different plausible email address in the resume to surface
  -- as a suggested correction. Either way this is a human decision, not
  -- an automatic decline or an automatic email rewrite.
  SELECT (regexp_matches(v_resume, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', 'g'))[1]
    INTO v_alt_email
   LIMIT 1;

  IF v_alt_email IS NOT NULL THEN
    INSERT INTO public.alerts (
      agency_id, alert_type, severity, title, message,
      module_reference, is_read, is_resolved
    ) VALUES (
      NEW.agency_id,
      'candidate_bounce_alt_email_found',
      'warning',
      'Bounce: resume shows a different email address -- verify before deciding',
      format(
        '%s -- mailed %s bounced, but the resume shows %s instead. Possible bad extraction. Check by hand: if %s is correct, update hiring_candidates.email and let the invite pipeline re-send; if it is not, decline (bounced_undeliverable). Bounce row id %s.',
        coalesce(v_name, NEW.candidate_id::text), NEW.bounced_email, v_alt_email, v_alt_email, NEW.id
      ),
      'assessment_invite_bounces:' || NEW.id::text,
      false, false
    );
  ELSE
    INSERT INTO public.alerts (
      agency_id, alert_type, severity, title, message,
      module_reference, is_read, is_resolved
    ) VALUES (
      NEW.agency_id,
      'candidate_bounce_unverifiable',
      'warning',
      'Bounce: resume text present but does not show the mailed address',
      format(
        '%s -- mailed %s bounced. Resume text exists but does not contain that address, and no alternate email address was found in it either -- could be a contact section the extraction dropped rather than a wrong address. Check by hand before declining. Bounce row id %s.',
        coalesce(v_name, NEW.candidate_id::text), NEW.bounced_email, NEW.id
      ),
      'assessment_invite_bounces:' || NEW.id::text,
      false, false
    );
  END IF;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_assessment_invite_bounce_apply
  ON public.assessment_invite_bounces;

CREATE TRIGGER trg_assessment_invite_bounce_apply
  AFTER INSERT ON public.assessment_invite_bounces
  FOR EACH ROW
  EXECUTE FUNCTION public.assessment_invite_bounce_apply();
