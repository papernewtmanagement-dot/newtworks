-- Migration: llm-queue-drainer dispatcher + automation recipe registration.
-- Applied via Supabase MCP on 2026-07-29.
--
-- Purpose: Wires the llm-queue-drainer edge function into the automation_recipes
-- cron pipeline. The dispatcher SQL function matches the required
-- handler(agency_id, recipe_id) → jsonb signature, calls the edge function via
-- extensions.http_post with the automation_runner shared secret, and returns
-- the response.
--
-- Rate limiting: Groq free-tier caps llama-3.3-70b-versatile at 12000 tokens
-- per minute. max_items=1 per invocation keeps a single bank statement (~7-8K
-- input tokens + 4K max output) inside the ceiling. Every-2-min cron drains
-- ~30 items per hour worst case — steady state a handful per week.

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
  PERFORM extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS','5000');
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS','45000');

  SELECT setting_value INTO v_secret FROM public.settings
    WHERE agency_id = p_agency_id AND setting_key = 'automation_runner_cron_secret';

  IF v_secret IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'automation_runner_cron_secret not set');
  END IF;

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

-- Register the automation recipe (idempotent — skips if already present).
INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression, timezone,
  internal_handler, is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'LLM Parse Queue Drainer',
  'Drains pending llm_parse_queue items (bank statements) that document-processor could not complete synchronously. Runs every 2 minutes; max_items=1 per run stays inside Groq free-tier TPM limits.',
  'cron',
  '*/2 * * * *',
  'UTC',
  'dispatch_llm_queue_drainer',
  TRUE
)
ON CONFLICT DO NOTHING;
