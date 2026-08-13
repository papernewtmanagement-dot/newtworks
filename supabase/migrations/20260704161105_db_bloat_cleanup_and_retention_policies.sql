-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-04 16:11:05 UTC (ledger name: db_bloat_cleanup_and_retention_policies) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260704161105.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- =========================================================================
-- DB bloat cleanup + retention policies
-- Peter approved 1-4, both A+B on 5, and 6 on 2026-07-04
-- =========================================================================

-- 1. Delete legacy_import_staging (100% posted, already in journal_entries)
DELETE FROM public.legacy_import_staging;

-- 2. Delete pre-XML-conversion snapshots
DELETE FROM public.persistent_memory
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND category IN ('persistent_memory_snapshot','principle_snapshot');

-- 3. Delete succeeded llm_parse_queue rows
DELETE FROM public.llm_parse_queue
WHERE status = 'succeeded';

-- 4. Pruning function for automation_run_log — successes > 30 days
CREATE OR REPLACE FUNCTION public.prune_automation_run_log()
RETURNS TABLE(deleted_count integer, run_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
AS $func$
DECLARE
  n integer;
BEGIN
  DELETE FROM public.automation_run_log
  WHERE status = 'success'
    AND run_at < NOW() - INTERVAL '30 days';
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN QUERY SELECT n, NOW();
END;
$func$;

-- 5A. Pruning function for session_notes — 30-day rolling window
CREATE OR REPLACE FUNCTION public.prune_session_notes()
RETURNS TABLE(deleted_count integer, run_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
AS $func$
DECLARE
  n integer;
BEGIN
  DELETE FROM public.persistent_memory
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND category = 'session_note'
    AND updated_at < NOW() - INTERVAL '30 days';
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN QUERY SELECT n, NOW();
END;
$func$;

-- Schedule both to run weekly Sunday 03:00 UTC (agency week is Sun-Sat)
SELECT cron.schedule(
  'prune_automation_run_log_weekly',
  '0 3 * * 0',
  $$SELECT public.prune_automation_run_log();$$
);

SELECT cron.schedule(
  'prune_session_notes_weekly',
  '15 3 * * 0',
  $$SELECT public.prune_session_notes();$$
);
