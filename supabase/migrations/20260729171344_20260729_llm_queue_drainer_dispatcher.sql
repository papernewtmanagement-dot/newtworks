-- Dispatcher SQL function matching the automation_recipes internal_handler signature.
-- Calls the llm-queue-drainer edge function via extensions.http_post.
CREATE OR REPLACE FUNCTION public.dispatch_llm_queue_drainer(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_secret text;
  v_url text := 'https://vulhdujhbwvibbojiimi.supabase.co/functions/v1/llm-queue-drainer';
  v_body text;
  v_resp jsonb;
BEGIN
  -- Ensure adequate timeout for one Groq roundtrip (~5-20s typical)
  PERFORM extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS','5000');
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS','45000');

  SELECT setting_value INTO v_secret FROM public.settings
    WHERE agency_id = p_agency_id AND setting_key = 'automation_runner_cron_secret';

  IF v_secret IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'automation_runner_cron_secret not set');
  END IF;

  -- max_items=1 keeps each invocation well inside Groq's 12000 TPM window on
  -- llama-3.3-70b-versatile free tier. Cron runs every 2 minutes so the queue
  -- drains steadily without ever tripping rate limits.
  v_body := jsonb_build_object(
    'agency_id', p_agency_id,
    'shared_secret', v_secret,
    'max_items', 1
  )::text;

  BEGIN
    v_resp := (extensions.http_post(v_url::varchar, v_body::varchar, 'application/json'::varchar)).content::jsonb;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'http_post failed: ' || SQLERRM);
  END;

  RETURN v_resp;
END;
$function$;
