-- A new hire's team record is built inactive when they accept the offer, and
-- nothing ever switched it on, so on their first day they were missing from the
-- time clock and everything else that lists the active team. This switches a
-- hire on once their start date arrives. Anyone ended, archived or terminated
-- is never touched.
CREATE OR REPLACE FUNCTION public.activate_team_on_start_date()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_n integer;
BEGIN
  UPDATE public.team t
  SET is_active = true, updated_at = now()
  WHERE t.is_active IS NOT TRUE
    AND t.start_date IS NOT NULL
    AND t.start_date <= (now() AT TIME ZONE 'America/Chicago')::date
    AND t.archived_at IS NULL
    AND t.end_date IS NULL
    AND t.termination_reason IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$function$;

REVOKE ALL ON FUNCTION public.activate_team_on_start_date() FROM PUBLIC, anon, authenticated;

SELECT cron.alter_job(1, command := $cmd$
    SELECT public.run_due_automation_recipes();
    SELECT public.resweep_failed_automation_dispatches();
    SELECT public.team_checkin_sweep_weekend_eod();
    SELECT public.activate_team_on_start_date();
    SELECT public.send_due_login_invites();
  $cmd$);

SELECT public.activate_team_on_start_date();
