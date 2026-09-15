-- The bundle-freshness GitHub Action already exists and already works. It caught
-- the stale document-processor bundle on 2026-09-12 and failed the run. Nobody
-- saw it, because a red mark on GitHub Actions is not a surface Peter reads.
-- This closes that half: poll the latest run on main and raise an alert when it
-- failed, so a broken build lands in Newtworks like every other problem does.
CREATE OR REPLACE FUNCTION public.check_ci_build_status()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $function$
DECLARE
  v_agency   uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_pat      text;
  v_body     jsonb;
  v_run      jsonb;
  v_sha      text;
  v_name     text;
  v_concl    text;
  v_url      text;
  v_raised   integer := 0;
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
  IF v_run IS NULL THEN RETURN 0; END IF;

  IF (v_run ->> 'status') <> 'completed' THEN RETURN 0; END IF;

  v_concl := v_run ->> 'conclusion';
  v_sha   := v_run ->> 'head_sha';
  v_name  := v_run ->> 'name';
  v_url   := v_run ->> 'html_url';

  IF v_concl IS DISTINCT FROM 'failure' THEN
    -- Green build closes any open alert, so a fixed build clears itself.
    UPDATE public.alerts
       SET is_resolved = true, resolved_at = NOW()
     WHERE agency_id = v_agency
       AND alert_type = 'ci_build_failed'
       AND is_resolved = false;
    RETURN 0;
  END IF;

  -- Already open for this exact commit, do not stack duplicates.
  IF EXISTS (
    SELECT 1 FROM public.alerts
     WHERE agency_id = v_agency
       AND alert_type = 'ci_build_failed'
       AND is_resolved = false
       AND message LIKE '%' || left(v_sha, 10) || '%'
  ) THEN RETURN 0; END IF;

  INSERT INTO public.alerts (agency_id, alert_type, severity, title, message,
                             module_reference, is_read, is_resolved)
  VALUES (
    v_agency, 'ci_build_failed', 'high',
    'Build check failed on main: ' || coalesce(v_name, 'unknown check'),
    'Commit ' || left(v_sha, 10) || ' failed the check "' || coalesce(v_name, '?') ||
    '". The usual cause is an edge function bundle that was not rebuilt after its '
    || 'source changed, which means the deployed function is running old code. '
    || 'Run: ' || v_url,
    'newtworks', false, false);

  v_raised := 1;
  RETURN v_raised;
END;
$function$;

REVOKE ALL ON FUNCTION public.check_ci_build_status() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_ci_build_status() TO service_role;
