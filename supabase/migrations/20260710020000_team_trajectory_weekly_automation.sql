-- Weekly automation handler: called by run_internal_recipe. Fires
-- team_trajectory_recompute(NULL, true) which uses pg_net to invoke the
-- team-trajectory-summarize edge function. Returns the expected shape for
-- automation-runner's pg_net dispatch reconciliation loop.
CREATE OR REPLACE FUNCTION public.team_trajectory_summaries_weekly(
  p_agency_id uuid,
  p_recipe_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_result jsonb;
  v_request_id bigint;
  v_active_count int;
BEGIN
  -- Guard: must be the Newtworks agency
  IF p_agency_id <> '126794dd-25ff-47d2-a436-724499733365'::uuid THEN
    RAISE EXCEPTION 'team_trajectory_summaries_weekly wired to Newtworks agency only';
  END IF;

  -- Count expected members for records_processed reporting
  SELECT COUNT(*) INTO v_active_count
  FROM public.team
  WHERE agency_id = p_agency_id
    AND is_active = true
    AND is_admin_backoffice = false
    AND archived_at IS NULL;

  -- Fire the recompute RPC (which itself uses net.http_post)
  v_result := public.team_trajectory_recompute(NULL::uuid, true);
  v_request_id := (v_result->>'request_id')::bigint;

  -- Return in the shape automation-runner expects. Presence of request_id
  -- tells the runner to poll for the pg_net response.
  RETURN jsonb_build_object(
    'records_processed', v_active_count,
    'output_summary',    format('Triggered trajectory summarization for %s active team members (request_id=%s)', v_active_count, v_request_id),
    'request_id',        v_request_id,
    'target_function',   'team-trajectory-summarize'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.team_trajectory_summaries_weekly(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.team_trajectory_summaries_weekly(uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.team_trajectory_summaries_weekly(uuid, uuid) IS
  'Weekly automation handler. Called by run_internal_recipe. Fires team_trajectory_recompute(NULL, true) which invokes the team-trajectory-summarize edge function via net.http_post. Returns records_processed/output_summary/request_id/target_function for automation-runner pg_net reconciliation.';

-- Recipe row: Sunday 12:00 UTC = 07:00 CDT (summer) / 06:00 CST (winter).
-- Early Sunday so summaries are fresh for the Monday coaching cycle.
INSERT INTO public.automation_recipes (
  agency_id,
  recipe_name,
  recipe_description,
  trigger_type,
  cron_expression,
  composio_action,
  internal_handler,
  is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Weekly Team Trajectory Summaries',
  'Every Sunday morning, refresh the LLM-summarized behavioral trajectory for each active non-admin-backoffice team member. Feeds the Assessment panel purple stripe in Team/Members expanded row. Reads last 90d team_behavioral_notes + latest team_assessments, prompts Groq openai/gpt-oss-120b, writes to team_trajectory_summaries.',
  'cron',
  '0 12 * * 0',
  'INTERNAL',
  'team_trajectory_summaries_weekly',
  true
);
