-- Outside calls from triggers wait for the save to finish (Peter 2026-09-25).
-- A trigger that calls Telegram through the http extension makes the call the
-- moment the row changes. BEGIN ... ROLLBACK undoes the row but not the call.
-- 2026-09-25 2:15 pm: a calendar test marked Cassie as leaving inside
-- BEGIN ... ROLLBACK; team_telegram_offboard kicked her from the team group
-- for real and posted a false "terminated" line to the admin group.
-- Every trigger that reaches an outside service is now a deferred constraint
-- trigger: it runs at COMMIT and never runs on ROLLBACK. Its WHEN test still
-- runs at once, so rows that do not qualify queue nothing.
--   1. team_telegram_offboard               team group removal
--   2. trg_notify_comp_net_deposit          deposit message to the admin group
--   3. trg_candidate_email_response_notify  hiring problem message to Peter,
--      split out of candidate_email_response_apply; status changes stay immediate.

-- 1. Team group removal
CREATE OR REPLACE FUNCTION public.trg_team_telegram_offboard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Deferred constraint trigger: runs at COMMIT, never on ROLLBACK, because
-- telegram_group_remove_member calls Telegram live and a live call cannot be
-- taken back. Reads the row as it stands at commit, so a person marked gone
-- and restored in the same transaction is left alone.
DECLARE
  v_gone boolean;
BEGIN
  SELECT (t.is_active IS FALSE OR t.archived_at IS NOT NULL)
    INTO v_gone
    FROM public.team t
   WHERE t.id = NEW.id;
  IF v_gone IS NOT TRUE THEN
    RETURN NULL;
  END IF;
  BEGIN
    PERFORM public.telegram_group_remove_member(NEW.id, 'terminated');
  EXCEPTION WHEN OTHERS THEN
    -- A Telegram hiccup must never block the termination itself.
    RAISE WARNING 'telegram offboard failed for %: %', NEW.id, SQLERRM;
  END;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS team_telegram_offboard ON public.team;
CREATE CONSTRAINT TRIGGER team_telegram_offboard
  AFTER UPDATE ON public.team
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  WHEN ((NEW.is_active IS FALSE AND OLD.is_active IS DISTINCT FROM FALSE)
        OR (NEW.archived_at IS NOT NULL AND OLD.archived_at IS NULL))
  EXECUTE FUNCTION public.trg_team_telegram_offboard();

-- 2. Deposit message
CREATE OR REPLACE FUNCTION public.tg_notify_comp_net_deposit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Deferred constraint trigger, once per inserted comp_recap row, at COMMIT.
-- The deposit message goes out through Telegram live, so it must never run
-- mid-transaction. Was a statement trigger with a transition table, which
-- cannot be deferred. Still one message per statement date: the first row of
-- a date inserts comp_deposit_notices and sends; comp_net_deposit_notice's
-- ON CONFLICT DO NOTHING makes every later row return already_sent.
BEGIN
  BEGIN
    -- Only current statements. A reprocessed old statement never re-sends.
    IF make_date(NEW.period_year, NEW.period_month, NEW.period_day)
       >= (now() AT TIME ZONE 'America/Chicago')::date - 45 THEN
      PERFORM public.comp_net_deposit_notice(NEW.agency_id, NEW.period_year, NEW.period_month, NEW.period_day, true);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL; -- a failed notice must never roll back the statement rows
  END;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_notify_comp_net_deposit ON public.comp_recap;
CREATE CONSTRAINT TRIGGER trg_notify_comp_net_deposit
  AFTER INSERT ON public.comp_recap
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  WHEN (NEW.source_document_id IS NOT NULL AND NEW.period_year IS NOT NULL
        AND NEW.period_month IS NOT NULL AND NEW.period_day IS NOT NULL)
  EXECUTE FUNCTION public.tg_notify_comp_net_deposit();

-- 3. Hiring problem message
CREATE OR REPLACE FUNCTION public.candidate_email_response_notify()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Deferred constraint trigger: the hiring problem Telegram to Peter goes out
-- at COMMIT, never on ROLLBACK. Split out of candidate_email_response_apply
-- 2026-09-25 so the status changes stay immediate and only the live call
-- waits. Fires for every process_problem row, matched or not: a problem
-- relayed by Indeed matches no candidate row, and Peter still needs it.
BEGIN
  BEGIN
    PERFORM public.notify_candidate_process_problem(NEW.id);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'hiring problem notice failed for %: %', NEW.id, SQLERRM;
  END;
  RETURN NULL;
END;
$function$;

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
  IF NEW.hiring_candidate_id IS NOT NULL THEN
    SELECT btrim(coalesce(hc.first_name,'') || ' ' || coalesce(hc.last_name,'')), hc.status
      INTO v_name, v_status
      FROM public.hiring_candidates hc
     WHERE hc.id = NEW.hiring_candidate_id;
  END IF;

  -- The hiring problem Telegram to Peter is sent by its own deferred trigger,
  -- trg_candidate_email_response_notify, at commit (2026-09-25). It fires for
  -- every process_problem row, matched or not: a problem report relayed by
  -- Indeed matches no candidate row, and that is exactly the case Peter still
  -- needs to hear about.

  IF NEW.hiring_candidate_id IS NULL THEN
    NULL;

    UPDATE public.candidate_email_responses
       SET action_taken = CASE
             WHEN NEW.response_type = 'process_problem'
               THEN 'problem reported -- Telegram sent to Peter; sender not matched to a candidate, alert raised'
             ELSE 'logged only -- sender not matched to a candidate, alert raised'
           END
     WHERE id = NEW.id;

    RETURN NULL;
  END IF;

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

  ELSIF NEW.response_type = 'process_problem' THEN
    -- No status change. They still want the job; something is in their way.
    v_action := 'problem reported -- Telegram sent to Peter, alert raised, no status change';

  ELSIF NEW.response_type = 'bounced_undeliverable' THEN
    NULL;
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

DROP TRIGGER IF EXISTS trg_candidate_email_response_notify ON public.candidate_email_responses;
CREATE CONSTRAINT TRIGGER trg_candidate_email_response_notify
  AFTER INSERT ON public.candidate_email_responses
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  WHEN (NEW.response_type = 'process_problem')
  EXECUTE FUNCTION public.candidate_email_response_notify();
