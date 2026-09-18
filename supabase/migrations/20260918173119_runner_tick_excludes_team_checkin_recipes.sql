-- pg_cron job 1 (automation-runner-tick) moved from :59 to :00 on 2026-09-17.
-- Job 23 (team-checkin-minute-tick) also fires at minute 0. Both dispatchers
-- saw the same team check-in recipes as due at the top of the hour and both
-- dispatched them ~1 second apart, so the midday and EOD messages were each
-- sent twice (2026-09-18: midday 71 + 72, EOD 76 + 77). The second send
-- overwrote the stored message id, orphaning the first message so the
-- delete-prior chain could never take it down.
-- Fix: the team check-in recipes belong to job 23 only. One dispatcher per
-- recipe class.
CREATE OR REPLACE FUNCTION public.run_due_automation_recipes()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_now    TIMESTAMPTZ := date_trunc('minute', NOW());
  v_from   TIMESTAMPTZ := date_trunc('minute', NOW()) - INTERVAL '119 minutes';
  v_recipe RECORD;
  v_fired  INTEGER := 0;
BEGIN
  -- Hourly tick (pg_cron job 1 runs on the hour). A recipe is due when its
  -- cron expression matched any minute in the last two hours that is later
  -- than its last run. One fire per recipe per tick. Earliest slot first so
  -- same-hour sequences (ingest, then check) keep their designed order. The
  -- two-hour look-back means one skipped tick loses nothing; the last-run
  -- guard means a wider window never double-fires.
  --
  -- Team check-in recipes are EXCLUDED. They have their own dispatcher,
  -- run_due_team_checkin_recipes() on pg_cron job 23, which also fires at
  -- minute 0. Two dispatchers racing on the same recipe sends the message
  -- twice. Do not add these handlers back here.
  FOR v_recipe IN
    SELECT r.id, r.agency_id, r.recipe_name, m.slot
    FROM public.automation_recipes r
    CROSS JOIN LATERAL (
      SELECT min(s.minute) AS slot
      FROM generate_series(v_from, v_now, INTERVAL '1 minute') AS s(minute)
      WHERE s.minute > COALESCE(
              r.last_run_at,
              (SELECT max(l.run_at) FROM public.automation_run_log l WHERE l.recipe_id = r.id),
              '-infinity'::timestamptz)
        AND public.cron_expression_matches(r.cron_expression, s.minute, r.timezone)
    ) m
    WHERE r.is_active = TRUE
      AND r.trigger_type = 'cron'
      AND r.cron_expression IS NOT NULL
      AND length(trim(r.cron_expression)) > 0
      AND COALESCE(r.internal_handler, '') NOT IN (
            'team_checkin_send_reminder',
            'team_checkin_tag_missing',
            'team_checkin_compile_results')
      AND m.slot IS NOT NULL
    ORDER BY m.slot, r.recipe_name
  LOOP
    BEGIN
      PERFORM public.run_automation_recipe(v_recipe.id, 'pg_cron');
      v_fired := v_fired + 1;
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO public.automation_run_log (
        agency_id, recipe_id, status, error_message, output_summary, run_at
      ) VALUES (
        v_recipe.agency_id, v_recipe.id, 'failed', SQLERRM,
        'tick dispatch failed: ' || v_recipe.recipe_name, NOW()
      );
    END;
  END LOOP;

  RETURN v_fired;
END;
$function$;
