-- RPC to trigger the team-trajectory-summarize edge function.
-- Owner/manager only. Calls the edge fn via net.http_post with shared_secret from settings.
CREATE OR REPLACE FUNCTION public.team_trajectory_recompute(
  p_team_member_id uuid DEFAULT NULL,
  p_all_active boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_agency_id uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_secret text;
  v_url text;
  v_body jsonb;
  v_request_id bigint;
BEGIN
  IF p_team_member_id IS NULL AND NOT p_all_active THEN
    RAISE EXCEPTION 'must pass p_team_member_id or p_all_active=true';
  END IF;

  SELECT setting_value INTO v_secret
  FROM public.settings
  WHERE agency_id = v_agency_id AND setting_key = 'automation_runner_cron_secret';
  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'automation_runner_cron_secret not set';
  END IF;

  v_url := 'https://vulhdujhbwvibbojiimi.supabase.co/functions/v1/team-trajectory-summarize';

  IF p_all_active THEN
    v_body := jsonb_build_object(
      'agency_id',      v_agency_id,
      'all_active',     true,
      'shared_secret',  v_secret
    );
  ELSE
    v_body := jsonb_build_object(
      'agency_id',      v_agency_id,
      'team_member_id', p_team_member_id,
      'shared_secret',  v_secret
    );
  END IF;

  SELECT net.http_post(
    url     := v_url,
    body    := v_body,
    headers := jsonb_build_object('Content-Type','application/json'),
    timeout_milliseconds := 60000
  ) INTO v_request_id;

  RETURN jsonb_build_object(
    'request_id', v_request_id,
    'mode', CASE WHEN p_all_active THEN 'all_active' ELSE 'single' END,
    'team_member_id', p_team_member_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.team_trajectory_recompute(uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.team_trajectory_recompute(uuid, boolean) TO authenticated;

COMMENT ON FUNCTION public.team_trajectory_recompute(uuid, boolean) IS
  'Triggers team-trajectory-summarize edge fn via net.http_post. Owner/manager only via RLS + app-layer role gate.';
