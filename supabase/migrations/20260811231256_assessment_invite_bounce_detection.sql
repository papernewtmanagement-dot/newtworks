-- =========================================================================
-- Assessment invite bounce detection + self-healing
-- =========================================================================
-- Why: "Send v1 Assessment Invitations" reminders (attempts 2/3) never
-- checked whether attempt 1 actually delivered. A bad address just got
-- silently retried 2 more times then labeled no_response -- indistinguishable
-- from a candidate who saw the email and ignored it. Two real candidates
-- (Tatyana McCullough, Yzabel Lugo) sat invisible in that state on
-- 2026-08-11 until a human happened to notice the bounce in the inbox.
--
-- Fix: a recipe polls Gmail for "Address not found" bounce notifications,
-- writes each to assessment_invite_bounces, a trigger matches the bounced
-- address to a candidate and immediately pauses the reminder chain (outcome
-- = 'bounced', next_attempt_at = NULL) instead of letting it burn attempts
-- 2 and 3 on a dead address, and raises an alert. When the email is later
-- corrected on hiring_candidates, a second trigger flips the invitation back
-- to 'sent' with next_attempt_at = NOW() so the existing reminder cron
-- (already running every 15 min) resumes it automatically -- no manual
-- resend step needed going forward.
-- =========================================================================

-- 1. New terminal outcome value.
ALTER TABLE public.assessment_invitations DROP CONSTRAINT assessment_invitations_outcome_check;
ALTER TABLE public.assessment_invitations ADD CONSTRAINT assessment_invitations_outcome_check
  CHECK (outcome = ANY (ARRAY['sent'::text, 'completed'::text, 'declined'::text, 'no_response'::text, 'send_failed'::text, 'exited'::text, 'bounced'::text]));

-- 2. Raw bounce log. One row per DSN failure message. Dedup on
-- (agency_id, source_message_id) so a re-run of the polling recipe never
-- double-processes the same bounce email.
CREATE TABLE IF NOT EXISTS public.assessment_invite_bounces (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  source_message_id text NOT NULL,
  bounced_email text NOT NULL,
  candidate_id uuid REFERENCES public.hiring_candidates(id) ON DELETE SET NULL,
  matched boolean NOT NULL DEFAULT false,
  detected_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, source_message_id)
);

-- 3. Match + pause + alert. Fires after every new bounce row lands.
CREATE OR REPLACE FUNCTION public.handle_assessment_invite_bounce()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_candidate_id uuid;
  v_candidate_name text;
BEGIN
  SELECT id, coalesce(candidate_name, trim(concat_ws(' ', first_name, last_name)))
    INTO v_candidate_id, v_candidate_name
  FROM public.hiring_candidates
  WHERE agency_id = NEW.agency_id
    AND lower(email) = lower(NEW.bounced_email)
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_candidate_id IS NULL THEN
    -- Not tied to a hiring candidate we know about (could be a bounce from
    -- some other outbound mail this account sends). Leave matched=false,
    -- no alert -- nothing actionable on the hiring side.
    RETURN NEW;
  END IF;

  UPDATE public.assessment_invite_bounces
  SET candidate_id = v_candidate_id, matched = true
  WHERE id = NEW.id;

  -- Stop the reminder chain cold. Do NOT let attempts 2/3 fire at a dead address.
  UPDATE public.assessment_invitations
  SET outcome = 'bounced', next_attempt_at = NULL, updated_at = now()
  WHERE candidate_id = v_candidate_id
    AND agency_id = NEW.agency_id
    AND outcome = 'sent';

  INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, related_id, is_read, is_resolved, created_at)
  VALUES (
    NEW.agency_id,
    'assessment_invite_bounced',
    'warning',
    'Assessment invite bounced',
    coalesce(v_candidate_name, 'A candidate') || '''s assessment invitation to ' || NEW.bounced_email || ' could not be delivered. Correct the email on the candidate record -- the invite will resend automatically once it''s fixed.',
    'hiring',
    v_candidate_id,
    false,
    false,
    now()
  );

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_handle_assessment_invite_bounce ON public.assessment_invite_bounces;
CREATE TRIGGER trg_handle_assessment_invite_bounce
AFTER INSERT ON public.assessment_invite_bounces
FOR EACH ROW EXECUTE FUNCTION public.handle_assessment_invite_bounce();

-- 4. Self-heal: correcting the email on a candidate with a paused/bounced
-- invitation automatically resumes it via the existing reminder cron.
CREATE OR REPLACE FUNCTION public.resume_bounced_invitation_on_email_fix()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.email IS DISTINCT FROM OLD.email AND NEW.email IS NOT NULL AND NEW.email <> '' THEN
    UPDATE public.assessment_invitations
    SET outcome = 'sent', next_attempt_at = now(), updated_at = now()
    WHERE candidate_id = NEW.id
      AND outcome = 'bounced';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_resume_bounced_invitation_on_email_fix ON public.hiring_candidates;
CREATE TRIGGER trg_resume_bounced_invitation_on_email_fix
AFTER UPDATE OF email ON public.hiring_candidates
FOR EACH ROW EXECUTE FUNCTION public.resume_bounced_invitation_on_email_fix();

-- 5. Polling recipe: Gmail -> LLM extraction -> assessment_invite_bounces
INSERT INTO automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
  composio_action, composio_connection, groq_prompt, input_config,
  output_table, output_config, is_active, timezone
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Detect Assessment Invite Bounces',
  'Polls Gmail every 15 min for "Address not found" bounce notifications (Delivery Status Notification failures). Extracts the bounced recipient address per message via LLM, writes to assessment_invite_bounces. A DB trigger on that table matches the bounced address to a hiring_candidates row, pauses that candidate''s reminder chain (assessment_invitations.outcome -> bounced, next_attempt_at -> NULL) instead of letting attempts 2/3 silently retry a dead address, and raises an alert. A second trigger on hiring_candidates auto-resumes (outcome -> sent, next_attempt_at -> NOW()) the moment the email is corrected, so the existing "Send v1 Assessment Invitations" cron picks it back up with no manual resend step. Added 2026-08-11 after two candidates (Tatyana McCullough, Yzabel Lugo) sat silently mislabeled no_response for a day+ on bounced invites nobody had flagged.',
  'cron',
  '*/15 * * * *',
  'GMAIL_FETCH_EMAILS',
  'gmail',
  'You read raw Gmail message data for "Delivery Status Notification (Failure)" bounce emails (the automated mailer-daemon reply Gmail sends when a message could not be delivered). For EVERY message given, extract: (1) messageId - copy the messageId field exactly as given, (2) bounced_email - the recipient email address that could not be delivered to, read from the body text (it appears after phrasing like "wasn''t delivered to X because" or "Delivery to the following recipient failed permanently: X"). If a message is not actually a delivery-failure bounce, or no recipient address can be found in it, omit it from the output entirely -- do not guess. Return JSON: {"records": [{"source_message_id": "<messageId>", "bounced_email": "<address>"}]}.',
  '{"gmail_query": "in:inbox subject:\"Delivery Status Notification\"", "archive_after_parse": true}'::jsonb,
  'assessment_invite_bounces',
  '{"unique_on": ["agency_id", "source_message_id"], "on_conflict": "ignore"}'::jsonb,
  true,
  'America/Chicago'
);
