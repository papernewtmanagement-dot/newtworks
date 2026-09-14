-- 1. prune_automation_run_log: the RETURNS TABLE out-param "run_at" collided with
--    automation_run_log.run_at inside the DELETE, so the weekly prune has been
--    erroring out ("column reference run_at is ambiguous"). Qualify the column.
--    Signature and output names left untouched.
CREATE OR REPLACE FUNCTION public.prune_automation_run_log()
 RETURNS TABLE(deleted_count integer, run_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  n integer;
BEGIN
  DELETE FROM public.automation_run_log
  WHERE automation_run_log.status = 'success'
    AND automation_run_log.run_at < NOW() - INTERVAL '30 days';
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN QUERY SELECT n, NOW();
END;
$function$;

-- 2. Job 18 (suspense_aging_daily) calls public.check_suspense_aging(uuid), which
--    migration 20260808022601 deliberately dropped in the finance rebuild
--    ("no suspense account ... any more"). The job was never unscheduled, so it has
--    errored every morning since. Remove the orphan; do NOT recreate the function.
SELECT cron.unschedule('suspense_aging_daily');

-- 3. Job 20 (statement_reconciliation_weekly) calls
--    fn_check_statement_reconciliation() with no arguments, but the function was
--    later rewritten to the 2-arg recipe-wrapper convention (agency_id, recipe_id),
--    so the job has errored every Sunday. The work already has an automation_recipes
--    row. Per the standing no-new-pg_cron rule, retire the job and let the recipe
--    carry it on the hourly tick.
SELECT cron.unschedule('statement_reconciliation_weekly');

UPDATE public.automation_recipes
SET is_active = TRUE, updated_at = NOW()
WHERE recipe_name = 'Statement reconciliation check'
  AND internal_handler = 'fn_check_statement_reconciliation';
