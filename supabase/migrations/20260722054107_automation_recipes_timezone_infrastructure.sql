-- Step 1: Add timezone column. Default 'UTC' means every existing recipe
-- keeps behaving identically until its row is explicitly flipped to a CT tz.
ALTER TABLE public.automation_recipes
  ADD COLUMN IF NOT EXISTS timezone text NOT NULL DEFAULT 'UTC';

COMMENT ON COLUMN public.automation_recipes.timezone IS
  'IANA timezone the cron_expression is anchored to (e.g. UTC, America/Chicago). run_due_automation_recipes converts NOW() to this timezone before evaluating the cron. Postgres handles DST natively.';

-- Step 2: New 3-arg cron_expression_matches. Converts p_at to the given
-- timezone before extracting hour/minute/day-of-week/day/month, so cron
-- strings can be written in local wall-clock terms.
CREATE OR REPLACE FUNCTION public.cron_expression_matches(p_cron text, p_at timestamptz, p_timezone text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  v_parts        TEXT[];
  v_minute_part  TEXT;
  v_hour_part    TEXT;
  v_dom_part     TEXT;
  v_month_part   TEXT;
  v_dow_part     TEXT;
  -- Convert to the recipe's local timezone. Result is a timestamp WITHOUT
  -- time zone whose components are the local wall-clock time. Postgres
  -- handles DST transitions natively.
  v_at_local     TIMESTAMP := date_trunc('minute', (p_at AT TIME ZONE COALESCE(p_timezone, 'UTC')));
  v_minute       INT := EXTRACT(MINUTE FROM v_at_local)::INT;
  v_hour         INT := EXTRACT(HOUR FROM v_at_local)::INT;
  v_dom          INT := EXTRACT(DAY FROM v_at_local)::INT;
  v_month        INT := EXTRACT(MONTH FROM v_at_local)::INT;
  v_dow          INT := EXTRACT(DOW FROM v_at_local)::INT;
BEGIN
  v_parts := regexp_split_to_array(trim(p_cron), '\s+');
  IF array_length(v_parts, 1) <> 5 THEN
    RETURN FALSE;
  END IF;

  v_minute_part := v_parts[1];
  v_hour_part   := v_parts[2];
  v_dom_part    := v_parts[3];
  v_month_part  := v_parts[4];
  v_dow_part    := v_parts[5];

  RETURN
    public.cron_field_matches(v_minute_part, v_minute, 0,  59) AND
    public.cron_field_matches(v_hour_part,   v_hour,   0,  23) AND
    public.cron_field_matches(v_dom_part,    v_dom,    1,  31) AND
    public.cron_field_matches(v_month_part,  v_month,  1,  12) AND
    public.cron_field_matches(v_dow_part,    v_dow,    0,   6);
END;
$function$;

-- Step 3: Drop the old 2-arg signature per op-rule "Function-signature changes:
-- drop old overload or all short-arg callers break". Old callers must adapt.
DROP FUNCTION IF EXISTS public.cron_expression_matches(text, timestamptz);

-- Step 4: Update run_due_automation_recipes to pass each recipe's timezone.
CREATE OR REPLACE FUNCTION public.run_due_automation_recipes()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_now           TIMESTAMPTZ := date_trunc('minute', NOW());
  v_recipe        RECORD;
  v_fired_count   INTEGER := 0;
BEGIN
  FOR v_recipe IN
    SELECT id, agency_id, recipe_name, cron_expression, timezone, last_run_at
    FROM public.automation_recipes
    WHERE is_active = TRUE
      AND trigger_type = 'cron'
      AND cron_expression IS NOT NULL
      AND length(trim(cron_expression)) > 0
      AND (last_run_at IS NULL OR date_trunc('minute', last_run_at) < v_now)
  LOOP
    IF public.cron_expression_matches(v_recipe.cron_expression, v_now, v_recipe.timezone) THEN
      BEGIN
        PERFORM public.run_automation_recipe(v_recipe.id, 'pg_cron');
        v_fired_count := v_fired_count + 1;
      EXCEPTION WHEN OTHERS THEN
        INSERT INTO public.automation_run_log (
          agency_id, recipe_id, status, error_message, output_summary, run_at
        ) VALUES (
          v_recipe.agency_id, v_recipe.id, 'failed', SQLERRM,
          'tick dispatch failed: ' || v_recipe.recipe_name, NOW()
        );
      END;
    END IF;
  END LOOP;

  RETURN v_fired_count;
END;
$function$;
