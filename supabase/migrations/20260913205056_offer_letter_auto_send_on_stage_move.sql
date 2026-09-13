-- Peter ruled on 2026-08-24 that offer letters fire automatically when a
-- candidate lands in the Offer stage. Built 2026-09-13.
--
-- The offer form is the only path to status='offer' (CandidateDetail
-- intercepts the stage move and opens OfferLetterModal), and it writes the
-- status and the letter body in one UPDATE. So the popup that confirms the
-- terms IS the confirmation step, and this trigger fires the moment it saves.

-- The subject line needs a home Peter can edit. Seeded with the subject the
-- hand-sent letters actually used.
ALTER TABLE public.offer_letter_templates
  ADD COLUMN IF NOT EXISTS subject text NOT NULL DEFAULT 'Reference Check & Next Steps';

CREATE OR REPLACE FUNCTION public.dispatch_offer_letter()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'pg_catalog'
AS $function$
DECLARE
  v_url    text;
  v_secret text;
BEGIN
  -- Guards. offer_sent_at IS NULL is the duplicate stop: without it, moving a
  -- candidate out of Offer and back would mail them a second time.
  IF NEW.is_test_candidate IS TRUE      THEN RETURN NULL; END IF;
  IF NEW.offer_sent_at IS NOT NULL      THEN RETURN NULL; END IF;
  IF NEW.offer_letter_body IS NULL      THEN RETURN NULL; END IF;
  IF btrim(NEW.offer_letter_body) = ''  THEN RETURN NULL; END IF;

  SELECT setting_value INTO v_url
  FROM public.settings
  WHERE agency_id = NEW.agency_id AND setting_key = 'supabase_url';

  SELECT setting_value INTO v_secret
  FROM public.settings
  WHERE agency_id = NEW.agency_id AND setting_key = 'automation_runner_cron_secret';

  -- No credentials = no dispatch. Silent: a missing setting must never block
  -- the offer from being saved on the candidate.
  IF v_url IS NULL OR v_secret IS NULL THEN RETURN NULL; END IF;

  -- pg_net queues the request and sends it after this transaction commits, so
  -- the edge function always reads the committed row. One decider: the trigger
  -- dispatches, the function decides and stamps offer_sent_at.
  PERFORM net.http_post(
    url     := v_url || '/functions/v1/hiring-interview-scheduler',
    headers := public.edge_fn_headers(),
    body    := jsonb_build_object(
                 'mode',          'send_offer_letter',
                 'agency_id',     NEW.agency_id,
                 'shared_secret', v_secret,
                 'candidate_id',  NEW.id
               ),
    timeout_milliseconds := 120000
  );

  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_send_offer_letter ON public.hiring_candidates;
CREATE TRIGGER trg_send_offer_letter
  AFTER UPDATE OF status, offer_letter_body ON public.hiring_candidates
  FOR EACH ROW
  WHEN (NEW.status = 'offer')
  EXECUTE FUNCTION public.dispatch_offer_letter();