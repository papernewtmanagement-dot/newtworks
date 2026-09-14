-- Decision 1: the last two hour-sensitive pg_cron jobs are pinned to UTC, so both
-- slide an hour earlier in Central on 2026-11-01. Move both onto America/Chicago
-- recipes riding the :59 tick, which converts explicitly and handles the time change
-- on its own. No new pg_cron jobs.

-- Job 12 (verify_pending_cpr_sends) was a straight duplicate: an active
-- America/Chicago recipe with the same handler already exists on '0 6-23 * * 0,1,6'.
-- The recipe also closes the gap the job had — the UTC window ended 18:40 Central,
-- before the 18:59 CPR nudge, so evening sends went unverified overnight.
SELECT cron.unschedule('verify_pending_cpr_sends');

-- Restate the surviving recipe's slots as the minute they actually fire, so the
-- table tells the truth about the :59 tick.
UPDATE public.automation_recipes
SET cron_expression = '59 6-23 * * 0,1,6', updated_at = NOW()
WHERE internal_handler = 'verify_pending_cpr_sends'
  AND cron_expression = '0 6-23 * * 0,1,6';

-- Job 21 (gl_rule_dormancy_audit_daily) has no recipe. The audit function does not
-- match the (agency_id, recipe_id) calling convention the runner uses, so add the
-- standard 2-arg wrapper, same shape as statement_gl_writer_recipe.
CREATE OR REPLACE FUNCTION public.gl_rule_dormancy_audit_recipe(
  p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.audit_dormant_gl_classification_rules(p_agency_id, INTERVAL '30 days');
  RETURN jsonb_build_object(
    'records_processed', COALESCE((v_result->>'dormant_count')::int, 0),
    'output_summary', COALESCE(v_result->>'summary',
                               'GL classification rule dormancy audit complete'),
    'detail', v_result);
END;
$function$;

INSERT INTO public.automation_recipes
  (agency_id, recipe_name, trigger_type, cron_expression, timezone,
   internal_handler, is_active, created_at, updated_at)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365',
   'GL Rule Dormancy Audit', 'cron', '59 8 * * *', 'America/Chicago',
   'gl_rule_dormancy_audit_recipe', TRUE, NOW(), NOW());

SELECT cron.unschedule('gl_rule_dormancy_audit_daily');
