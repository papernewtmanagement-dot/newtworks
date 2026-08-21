CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE OR REPLACE FUNCTION public.get_setting(
  p_agency_id UUID,
  p_setting_key TEXT
) RETURNS TEXT
LANGUAGE sql
STABLE
AS $func$
  SELECT setting_value
  FROM public.settings
  WHERE agency_id = p_agency_id
    AND setting_key = p_setting_key
  LIMIT 1;
$func$;

CREATE OR REPLACE FUNCTION public.cron_field_matches(
  p_field    TEXT,
  p_value    INT,
  p_min      INT,
  p_max      INT
) RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $func$
DECLARE
  v_token   TEXT;
  v_step    INT;
  v_lo      INT;
  v_hi      INT;
  v_n       INT;
  v_token_main TEXT;
BEGIN
  IF position(',' IN p_field) > 0 THEN
    FOREACH v_token IN ARRAY string_to_array(p_field, ',') LOOP
      IF public.cron_field_matches(trim(v_token), p_value, p_min, p_max) THEN
        RETURN TRUE;
      END IF;
    END LOOP;
    RETURN FALSE;
  END IF;

  IF position('/' IN p_field) > 0 THEN
    v_token_main := split_part(p_field, '/', 1);
    v_step := split_part(p_field, '/', 2)::INT;
    IF v_token_main = '*' THEN
      v_lo := p_min;
      v_hi := p_max;
    ELSIF position('-' IN v_token_main) > 0 THEN
      v_lo := split_part(v_token_main, '-', 1)::INT;
      v_hi := split_part(v_token_main, '-', 2)::INT;
    ELSE
      v_lo := v_token_main::INT;
      v_hi := p_max;
    END IF;
    RETURN p_value BETWEEN v_lo AND v_hi
       AND ((p_value - v_lo) % v_step) = 0;
  END IF;

  IF position('-' IN p_field) > 0 THEN
    v_lo := split_part(p_field, '-', 1)::INT;
    v_hi := split_part(p_field, '-', 2)::INT;
    RETURN p_value BETWEEN v_lo AND v_hi;
  END IF;

  IF p_field = '*' THEN
    RETURN TRUE;
  END IF;

  v_n := p_field::INT;
  RETURN p_value = v_n;
EXCEPTION WHEN OTHERS THEN
  RETURN FALSE;
END;
$func$;

CREATE OR REPLACE FUNCTION public.cron_expression_matches(
  p_cron TEXT,
  p_at   TIMESTAMPTZ
) RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $func$
DECLARE
  v_parts        TEXT[];
  v_minute_part  TEXT;
  v_hour_part    TEXT;
  v_dom_part     TEXT;
  v_month_part   TEXT;
  v_dow_part     TEXT;
  v_at           TIMESTAMPTZ := date_trunc('minute', p_at);
  v_minute       INT := EXTRACT(MINUTE FROM v_at)::INT;
  v_hour         INT := EXTRACT(HOUR FROM v_at)::INT;
  v_dom          INT := EXTRACT(DAY FROM v_at)::INT;
  v_month        INT := EXTRACT(MONTH FROM v_at)::INT;
  v_dow          INT := EXTRACT(DOW FROM v_at)::INT;
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
$func$;

CREATE OR REPLACE FUNCTION public.run_automation_recipe(
  p_recipe_id UUID,
  p_triggered_by TEXT DEFAULT 'manual'
) RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
AS $func$
DECLARE
  v_recipe        RECORD;
  v_supabase_url  TEXT;
  v_runner_secret TEXT;
  v_request_id    BIGINT;
BEGIN
  SELECT * INTO v_recipe FROM public.automation_recipes WHERE id = p_recipe_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Recipe % not found', p_recipe_id;
  END IF;

  IF v_recipe.agency_id IS NULL THEN
    RAISE EXCEPTION 'Recipe % has no agency_id set.', p_recipe_id;
  END IF;

  v_supabase_url := public.get_setting(v_recipe.agency_id, 'supabase_url');
  IF v_supabase_url IS NULL THEN
    RAISE EXCEPTION 'settings.supabase_url missing for agency %', v_recipe.agency_id;
  END IF;

  v_runner_secret := public.get_setting(v_recipe.agency_id, 'automation_runner_cron_secret');
  IF v_runner_secret IS NULL THEN
    RAISE EXCEPTION 'settings.automation_runner_cron_secret missing for agency %', v_recipe.agency_id;
  END IF;

  SELECT net.http_post(
    url := v_supabase_url || '/functions/v1/automation-runner',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object(
      'shared_secret', v_runner_secret,
      'recipe_id',     p_recipe_id::text,
      'triggered_by',  p_triggered_by
    ),
    timeout_milliseconds := 240000
  ) INTO v_request_id;

  RETURN v_request_id;
END;
$func$;

CREATE OR REPLACE FUNCTION public.run_due_automation_recipes()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $func$
DECLARE
  v_now           TIMESTAMPTZ := date_trunc('minute', NOW());
  v_recipe        RECORD;
  v_fired_count   INTEGER := 0;
BEGIN
  FOR v_recipe IN
    SELECT id, agency_id, recipe_name, cron_expression, last_run_at
    FROM public.automation_recipes
    WHERE is_active = TRUE
      AND trigger_type = 'cron'
      AND cron_expression IS NOT NULL
      AND length(trim(cron_expression)) > 0
      AND (last_run_at IS NULL OR date_trunc('minute', last_run_at) < v_now)
  LOOP
    IF public.cron_expression_matches(v_recipe.cron_expression, v_now) THEN
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
$func$;

GRANT EXECUTE ON FUNCTION public.get_setting(UUID, TEXT) TO postgres, service_role, authenticated;
GRANT EXECUTE ON FUNCTION public.run_automation_recipe(UUID, TEXT) TO postgres, service_role, authenticated;
GRANT EXECUTE ON FUNCTION public.run_due_automation_recipes() TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.cron_expression_matches(TEXT, TIMESTAMPTZ) TO postgres, service_role, authenticated;
GRANT EXECUTE ON FUNCTION public.cron_field_matches(TEXT, INT, INT, INT) TO postgres, service_role, authenticated;
