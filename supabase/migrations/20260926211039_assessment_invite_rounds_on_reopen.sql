-- Assessment invites per ROUND (Peter decision 2026-09-26, "2B").
-- Before: invitations were counted across a candidate's whole history. A
-- declined candidate reopened to Applied who had already used attempt 3 got
-- no invite (step 2a needs zero invitations ever), no reminder (step 2b needs
-- the latest attempt under 3), and once back in Assessment Sent would be
-- re-declined by close_stale_assessment_sent because their FIRST-EVER invite
-- was more than 14 days old.
-- Now: reopening a declined or former candidate to Applied stamps
-- assessment_round_started_at, and the invite, reminder and stale-close logic
-- only count invitations sent since then. A reopen gets a fresh first invite
-- plus the usual two reminders. Candidates never reopened have a NULL round
-- start and behave exactly as before.

ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS assessment_round_started_at timestamptz;

COMMENT ON COLUMN public.hiring_candidates.assessment_round_started_at IS
  'Start of the current assessment-invite round. Stamped when a declined or former candidate is reopened to applied (trg_start_assessment_round_on_reopen). send_v1_assessment_invitations and close_stale_assessment_sent only count invitations sent since this. NULL = never reopened, whole history counts.';

CREATE OR REPLACE FUNCTION public.start_assessment_round_on_reopen()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
BEGIN
  NEW.assessment_round_started_at := now();
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_start_assessment_round_on_reopen ON public.hiring_candidates;
CREATE TRIGGER trg_start_assessment_round_on_reopen
  BEFORE UPDATE OF status ON public.hiring_candidates
  FOR EACH ROW
  WHEN (NEW.status = 'applied' AND OLD.status IN ('declined', 'former'))
  EXECUTE FUNCTION public.start_assessment_round_on_reopen();

-- send_v1_assessment_invitations: patch the three places that read invitation
-- history, leave everything else byte-for-byte as it is.
DO $mig$
DECLARE
  v_src text := pg_get_functiondef('public.send_v1_assessment_invitations(uuid,uuid)'::regprocedure);
  v_pairs text[][] := ARRAY[
    ARRAY[
      E'AS $function$\n  -- 2026-09-12:',
      E'AS $function$\n  -- 2026-09-26: invitations are counted per ROUND. Reopening a declined or\n  -- former candidate to Applied stamps hiring_candidates.assessment_round_started_at\n  -- (trigger trg_start_assessment_round_on_reopen). Steps 1d, 2a and 2b only look\n  -- at invitations sent since then, so a reopen gets a fresh invite plus the usual\n  -- two reminders instead of being skipped for having used up attempt 3.\n  -- close_stale_assessment_sent counts its days from the same round start.\n  -- 2026-09-12:'],
    ARRAY[
      E'    AND NOT EXISTS (SELECT 1 FROM public.assessment_invitations ai WHERE ai.candidate_id = hc.id)\n',
      E'    AND NOT EXISTS (SELECT 1 FROM public.assessment_invitations ai WHERE ai.candidate_id = hc.id\n                      AND ai.sent_at >= COALESCE(hc.assessment_round_started_at, ''-infinity''::timestamptz))\n'],
    ARRAY[
      E'      AND NOT EXISTS (\n        SELECT 1 FROM public.assessment_invitations ai\n        WHERE ai.candidate_id = hc.id\n      )\n',
      E'      AND NOT EXISTS (\n        SELECT 1 FROM public.assessment_invitations ai\n        WHERE ai.candidate_id = hc.id\n          AND ai.sent_at >= COALESCE(hc.assessment_round_started_at, ''-infinity''::timestamptz)\n      )\n'],
    ARRAY[
      E'      FROM public.assessment_invitations ai\n      WHERE ai.candidate_id = hc.id\n        AND ai.agency_id = p_agency_id\n      ORDER BY ai.attempt_number DESC\n',
      E'      FROM public.assessment_invitations ai\n      WHERE ai.candidate_id = hc.id\n        AND ai.agency_id = p_agency_id\n        AND ai.sent_at >= COALESCE(hc.assessment_round_started_at, ''-infinity''::timestamptz)\n      ORDER BY ai.attempt_number DESC\n']
  ];
  i int;
  v_n int;
BEGIN
  FOR i IN 1 .. array_length(v_pairs, 1) LOOP
    v_n := (length(v_src) - length(replace(v_src, v_pairs[i][1], ''))) / length(v_pairs[i][1]);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'send_v1_assessment_invitations patch % matched % times, expected 1', i, v_n;
    END IF;
    v_src := replace(v_src, v_pairs[i][1], v_pairs[i][2]);
  END LOOP;
  EXECUTE v_src;
END
$mig$;

CREATE OR REPLACE FUNCTION public.close_stale_assessment_sent(p_agency_id uuid, p_recipe_id uuid, p_days integer DEFAULT 14)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- 2026-09-26: counts from the first invite of the CURRENT round
-- (hiring_candidates.assessment_round_started_at), not the first invite ever.
-- A candidate reopened to Applied would otherwise be re-declined on the next
-- run because their original invite was long past the window.
DECLARE
  v_closed int := 0;
BEGIN
  WITH first_inv AS (
    SELECT ai.candidate_id, min(ai.sent_at) AS first_sent
    FROM public.assessment_invitations ai
    JOIN public.hiring_candidates h ON h.id = ai.candidate_id
    WHERE ai.agency_id = p_agency_id
      AND ai.sent_at >= COALESCE(h.assessment_round_started_at, '-infinity'::timestamptz)
    GROUP BY ai.candidate_id
  ),
  closed AS (
    UPDATE public.hiring_candidates hc
       SET status = 'declined',
           decline_reason = 'assessment_not_taken'
      FROM first_inv f
     WHERE f.candidate_id = hc.id
       AND hc.agency_id = p_agency_id
       AND hc.status = 'assessment_sent'
       AND hc.is_test_candidate IS NOT TRUE
       AND hc.assessment_completed_at IS NULL
       AND hc.decision_at IS NULL
       AND f.first_sent < NOW() - (p_days || ' days')::interval
    RETURNING 1
  )
  SELECT count(*) INTO v_closed FROM closed;

  RETURN jsonb_build_object(
    'closed', v_closed,
    'window_days', p_days,
    'ran_at', NOW(),
    'records_processed', v_closed,
    'output_summary', v_closed || ' candidate(s) closed after ' || p_days ||
      ' days with no assessment taken'
  );
END;
$function$;
