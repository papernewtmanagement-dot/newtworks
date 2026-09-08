-- The LLM Parse Queue Drainer polled every 2 minutes: 21,082 runs in 30 days,
-- zero records processed, queue empty since 2026-08-31. Replace the poll with a
-- statement-level trigger so the drainer fires only when work actually lands.
-- Statement-level, not row-level: a bulk insert of 40 rows fires one call, not 40.

CREATE OR REPLACE FUNCTION public.fire_llm_parse_queue_drainer()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_recipe_id uuid;
BEGIN
  SELECT id INTO v_recipe_id
  FROM public.automation_recipes
  WHERE recipe_name = 'LLM Parse Queue Drainer' AND is_active = TRUE
  LIMIT 1;

  IF v_recipe_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Never let a drain dispatch failure roll back the insert that triggered it.
  BEGIN
    PERFORM public.run_automation_recipe(v_recipe_id, 'queue_insert');
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'fire_llm_parse_queue_drainer: dispatch failed: %', SQLERRM;
  END;

  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_fire_llm_parse_queue_drainer ON public.llm_parse_queue;
CREATE TRIGGER trg_fire_llm_parse_queue_drainer
AFTER INSERT ON public.llm_parse_queue
FOR EACH STATEMENT
EXECUTE FUNCTION public.fire_llm_parse_queue_drainer();

-- Safety net only: catches anything left pending after a failed dispatch or a retry
-- backoff. Not the primary path any more.
UPDATE public.automation_recipes
   SET cron_expression = '0 */6 * * *',
       recipe_description = 'Drains pending llm_parse_queue rows. Fires on insert via trg_fire_llm_parse_queue_drainer; the 6-hourly schedule is only a safety net for rows left pending after a failed dispatch or retry backoff.',
       updated_at = NOW()
 WHERE recipe_name = 'LLM Parse Queue Drainer'
   AND agency_id = '126794dd-25ff-47d2-a436-724499733365';
