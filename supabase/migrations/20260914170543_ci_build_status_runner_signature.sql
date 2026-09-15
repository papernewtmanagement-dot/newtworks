-- The runner calls internal handlers as fn(agency_id, recipe_id). Match that
-- contract on the one function rather than keeping a second no-arg twin around.
DROP FUNCTION IF EXISTS public.check_ci_build_status();

CREATE OR REPLACE FUNCTION public.check_ci_build_status(
  p_agency_id uuid,
  p_recipe_id uuid DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $function$
DECLARE
  v_pat    text;
  v_body   jsonb;
  v_run    jsonb;
  v_sha    text;
  v_name   text;
  v_concl  text;
  v_url    text;
BEGIN
  SELECT setting_value INTO v_pat
  FROM public.settings WHERE setting_key = 'github_pat_newtworks_commit';
  IF v_pat IS NULL THEN RETURN 0; END IF;

  SELECT content::jsonb INTO v_body
  FROM extensions.http((
    'GET',
    'https://api.github.com/repos/papernewtmanagement-dot/newtworks/actions/runs?branch=main&per_page=1',
    ARRAY[
      extensions.http_header('Authorization', 'Bearer ' || v_pat),
      extensions.http_header('User-Agent', 'newtworks-ci-watch')
    ],
    NULL, NULL)::extensions.http_request);

  v_run := v_body -> 'workflow_runs' -> 0;
  IF v_run IS NULL OR (v_run ->> 'status') <> 'completed' THEN RETURN 0; END IF;

  v_concl := v_run ->> 'conclusion';
  v_sha   := v_run ->> 'head_sha';
  v_name  := v_run ->> 'name';
  v_url   := v_run ->> 'html_url';

  IF v_concl IS DISTINCT FROM 'failure' THEN
    -- A green build clears itself, so this never needs hand-resolving.
    UPDATE public.alerts
       SET is_resolved = true, resolved_at = NOW()
     WHERE agency_id = p_agency_id
       AND alert_type = 'ci_build_failed'
       AND is_resolved = false;
    RETURN 0;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.alerts
     WHERE agency_id = p_agency_id
       AND alert_type = 'ci_build_failed'
       AND is_resolved = false
       AND message LIKE '%' || left(v_sha, 10) || '%'
  ) THEN RETURN 0; END IF;

  INSERT INTO public.alerts (agency_id, alert_type, severity, title, message,
                             module_reference, is_read, is_resolved)
  VALUES (
    p_agency_id, 'ci_build_failed', 'high',
    'Build check failed on main: ' || coalesce(v_name, 'unknown check'),
    'Commit ' || left(v_sha, 10) || ' failed the check "' || coalesce(v_name, '?') ||
    '". The usual cause is an edge function bundle that was not rebuilt after its '
    || 'source changed, which means the deployed function is still running old code. '
    || 'Run: ' || v_url,
    'newtworks', false, false);

  RETURN 1;
END;
$function$;

REVOKE ALL ON FUNCTION public.check_ci_build_status(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_ci_build_status(uuid, uuid) TO service_role;
