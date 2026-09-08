-- Prunes the two log-style tables that had no retention job.
-- Origin: 2026-09-07 outage. cron.job_run_details had grown to 279,267 rows / 57 MB
-- with no pruning; one-row inserts into it were taking up to 104 seconds and starved
-- the whole instance, taking auth / rest / realtime / storage down together.
-- Retention: 7 days of cron run history (enough to diagnose a bad week),
-- 30 days of finished parse-queue rows (unfinished rows are never touched).
CREATE OR REPLACE FUNCTION public.prune_operational_logs()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, cron
AS $$
DECLARE
  v_cron_deleted  bigint := 0;
  v_queue_deleted bigint := 0;
BEGIN
  DELETE FROM cron.job_run_details
  WHERE start_time < now() - interval '7 days';
  GET DIAGNOSTICS v_cron_deleted = ROW_COUNT;

  DELETE FROM public.llm_parse_queue
  WHERE status IN ('succeeded', 'abandoned', 'failed')
    AND COALESCE(completed_at, last_attempt_at, created_at) < now() - interval '30 days';
  GET DIAGNOSTICS v_queue_deleted = ROW_COUNT;

  RETURN jsonb_build_object(
    'cron_run_details_deleted', v_cron_deleted,
    'llm_parse_queue_deleted',  v_queue_deleted,
    'pruned_at',                now()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.prune_operational_logs() FROM PUBLIC, anon, authenticated;
