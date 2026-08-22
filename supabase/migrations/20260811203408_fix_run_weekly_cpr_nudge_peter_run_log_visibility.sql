CREATE OR REPLACE FUNCTION public.run_weekly_cpr_nudge_peter(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  -- nudge_peter_for_cpr_drafts contains its own automation_run_log inserts on
  -- every path. Visibility fix (2026-08-11, see op-rule) makes the runner's
  -- own second log row accurate instead of always "0 processed / no summary".
  v_result := public.nudge_peter_for_cpr_drafts();
  RETURN v_result || jsonb_build_object(
    'records_processed', CASE WHEN COALESCE((v_result->>'nudged')::boolean, false) THEN 1 ELSE 0 END,
    'output_summary', CASE
      WHEN v_result ? 'error' THEN 'ERROR: ' || (v_result->>'error')
      WHEN v_result ? 'skipped' THEN 'Skipped: ' || (v_result->>'skipped')
      WHEN COALESCE((v_result->>'nudged')::boolean, false) THEN 'Nudged Peter (state=' || COALESCE(v_result->>'state', 'unknown') || ')'
      ELSE 'Not nudged (state=' || COALESCE(v_result->>'state', 'unknown') || ')'
    END
  );
END;
$function$;
