CREATE OR REPLACE FUNCTION public.run_team_trajectory_refresh_weekly(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  -- Full recompute of trajectory metrics for this agency
  v_result := public.team_trajectory_recompute(p_agency_id, true);
  -- Visibility fix (2026-08-11): see op-rule on automation_run_log blind logging.
  -- This dispatch is fire-and-forget (async net.http_post to team-trajectory-summarize);
  -- records_processed reflects "one dispatch made," not candidates actually summarized,
  -- since that count isn't known synchronously here.
  RETURN v_result || jsonb_build_object(
    'records_processed', CASE WHEN v_result->>'request_id' IS NOT NULL THEN 1 ELSE 0 END,
    'output_summary', 'Dispatched team trajectory recompute (async, mode=' ||
      COALESCE(v_result->>'mode', 'unknown') || ', request_id=' || COALESCE(v_result->>'request_id', 'none') || ')'
  );
END;
$function$
