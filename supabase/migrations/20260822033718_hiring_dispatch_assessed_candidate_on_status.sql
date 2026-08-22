-- Assessment gate rewire (2026-08-21, Peter-approved).
--
-- The old trigger (trg_auto_decline_on_assessment_score) fired on
-- assessment_completed_at going NULL -> NOT NULL. That is the wrong moment:
-- v1-assessment writes assessment_completed_at in its FIRST update, while the
-- candidate is still 'assessment_sent', and only flips status to 'assessed' in
-- a LATER update once the aptitude, scenario and reliability scores have been
-- applied. So the trigger always saw the wrong status, bowed out, and never got
-- a second chance -- 17 decline-verdict candidates sat untouched in 'assessed'
-- going back to 2026-08-02.
--
-- The new trigger fires on status landing on 'assessed', which is the last
-- write of the completion sequence and the first moment every score exists.
-- It does not decide anything itself: it hands the candidate to the
-- hiring-interview-scheduler edge function, which already owns both outcomes
-- (decline + decline email, or interview invite + booking link) off one
-- verdict_assessment call. One decider, not two competing ones.
--
-- The old function auto_decline_on_assessment_score() is left in place,
-- detached, rather than dropped -- it is the rollback path.

CREATE OR REPLACE FUNCTION public.dispatch_assessed_candidate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'net', 'pg_catalog'
AS $function$
DECLARE
  v_url    text;
  v_secret text;
BEGIN
  -- Skip test rows, anyone already decided, and anyone who already holds an
  -- interview booking token (re-entering 'assessed' must not re-invite).
  IF NEW.is_test_candidate IS TRUE THEN RETURN NULL; END IF;
  IF NEW.decision_at IS NOT NULL THEN RETURN NULL; END IF;
  IF NEW.interview_invite_token IS NOT NULL THEN RETURN NULL; END IF;

  SELECT setting_value INTO v_url
  FROM public.settings
  WHERE agency_id = NEW.agency_id AND setting_key = 'supabase_url';

  SELECT setting_value INTO v_secret
  FROM public.settings
  WHERE agency_id = NEW.agency_id AND setting_key = 'automation_runner_cron_secret';

  -- No credentials = no dispatch. Silent: a missing setting must never block
  -- a candidate's status from being saved.
  IF v_url IS NULL OR v_secret IS NULL THEN RETURN NULL; END IF;

  -- pg_net queues the request and sends it after this transaction commits, so
  -- the edge function always reads the committed row.
  PERFORM net.http_post(
    url     := v_url || '/functions/v1/hiring-interview-scheduler',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body    := jsonb_build_object(
                 'mode',          'process_assessed',
                 'agency_id',     NEW.agency_id,
                 'shared_secret', v_secret,
                 'candidate_id',  NEW.id
               ),
    timeout_milliseconds := 120000
  );

  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_auto_decline_on_assessment_score ON public.hiring_candidates;
DROP TRIGGER IF EXISTS trg_dispatch_assessed_candidate ON public.hiring_candidates;

CREATE TRIGGER trg_dispatch_assessed_candidate
AFTER UPDATE OF status ON public.hiring_candidates
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM 'assessed' AND NEW.status = 'assessed')
EXECUTE FUNCTION public.dispatch_assessed_candidate();
