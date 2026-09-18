-- =========================================================================
-- Move the automation runner tick from :59 to :00
-- =========================================================================
-- Peter asked for this on 2026-09-14. It did not get done, and the reason it
-- did not get done was written into memory afterwards as though it had been
-- his decision. It was not. His instruction stands, so the tick moves.
--
-- What had to move with it: every recipe written "59 H" now reads "0 H", so
-- the schedule column tells the truth instead of being one minute shy of the
-- hour. The four Saturday close recipes are the only ones where the minute
-- ever mattered — at 23:59 with a :00 tick they would have been picked up by
-- the midnight tick and computed Sunday's week. At 23:00 they fire on the
-- 23:00 Saturday tick and still read today as Saturday.
--
-- Recipes on other minutes (the GL writers at 0/15/30 past 11) are untouched.
-- Their minute is there to order them inside one tick, and slot order is
-- preserved either way.
-- =========================================================================

SELECT cron.alter_job(1, schedule => '0 * * * *');

UPDATE public.automation_recipes
SET cron_expression = '0 ' || substring(cron_expression from 4),
    updated_at      = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND cron_expression LIKE '59 %';

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
