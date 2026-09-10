-- Team check-in messages are team-facing and must land on the exact minute Peter set
-- (8:25, 12:00/12:15/12:30, 17:00/17:15/17:30 Central). The main automation runner
-- only ticks at :59, so it cannot hit those minutes. This dispatcher is identical to
-- run_due_automation_recipes() but scoped to the Team Checkin recipes only, so giving
-- it a finer tick changes nothing for any other recipe.
CREATE OR REPLACE FUNCTION public.run_due_team_checkin_recipes()
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
      AND r.internal_handler IN (
            'team_checkin_send_reminder',
            'team_checkin_tag_missing',
            'team_checkin_compile_results')
      AND r.cron_expression IS NOT NULL
      AND length(trim(r.cron_expression)) > 0
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
        'checkin tick dispatch failed: ' || v_recipe.recipe_name, NOW()
      );
    END;
  END LOOP;

  RETURN v_fired;
END;
$function$;

-- Applied alongside this migration via direct statements (recorded here so a
-- fresh reset reproduces production):
--   Recipe cron_expression + input_config.local_time restored to Peter's locked
--   times: morning reminder 25 8 / 08:25, morning tag missing 30 8 / 08:30,
--   morning compile 40 8 / 08:40, midday 0 12 / 12:00, midday tag missing
--   15 12 / 12:15, midday compile 30 12 / 12:30, EOD 0 17 / 17:00, EOD tag
--   missing 15 17 / 17:15, EOD compile 30 17 / 17:30. All America/Chicago.
--   pg_cron job 23 'team-checkin-minute-tick':
--     SELECT cron.schedule('team-checkin-minute-tick',
--       '0,15,25,30,40 13,14,17,18,22,23 * * 1-5',
--       'SELECT public.run_due_team_checkin_recipes();');
