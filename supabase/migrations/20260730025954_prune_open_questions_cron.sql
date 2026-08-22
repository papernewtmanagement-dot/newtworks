
-- Auto-prune resolved/superseded open_questions after 30 days.
-- Mirrors the session_notes prune pattern (weekly, Sunday early morning).
-- The op-rule says "bridge, not graveyard" — this operationalizes the "if
-- it becomes noise, delete outright" line into a time-based auto-prune.

CREATE OR REPLACE FUNCTION public.prune_open_questions()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_deleted int;
BEGIN
  WITH del AS (
    DELETE FROM public.open_questions
    WHERE status IN ('resolved','superseded')
      AND resolved_at IS NOT NULL
      AND resolved_at < NOW() - INTERVAL '30 days'
    RETURNING id
  )
  SELECT count(*) INTO v_deleted FROM del;
  RETURN v_deleted;
END;
$function$;

COMMENT ON FUNCTION public.prune_open_questions() IS
  'Deletes open_questions rows with status=resolved OR status=superseded whose resolved_at is >30 days old. Mirrors prune_session_notes retention policy. Scheduled via pg_cron.';

-- Weekly at 03:20 UTC Sunday (5 min after session_notes prune at 03:15)
SELECT cron.schedule(
  'prune_open_questions_weekly',
  '20 3 * * 0',
  $$SELECT public.prune_open_questions();$$
);

