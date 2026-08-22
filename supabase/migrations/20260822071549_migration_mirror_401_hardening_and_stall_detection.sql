-- Two defects, one migration.
--
-- (1) THE 401. Every edge-function deploy resets verify_jwt to true for a few
--     seconds. A nightly dispatch landing in that window is rejected at the
--     Supabase gateway with UNAUTHORIZED_NO_AUTH_HEADER. Fix: send an
--     Authorization header. The gateway is satisfied; authorization itself is
--     still enforced inside the function by the shared-secret check, which is
--     unchanged.
--
-- (2) THE SILENCE. A gateway rejection means the function body never runs, so
--     it cannot write its own failure alert. Verified: the 2026-08-22 07:05
--     401 produced zero alert rows. Checking net._http_response afterwards does
--     not work as a fix — pg_net prunes those rows in hours and the nightly
--     runs a day apart, so the evidence is usually gone. Instead the function
--     now records every successful run, and the handler alerts when no
--     successful run has landed in 26 hours. That detects ANY silent failure
--     mode, not just this one.

CREATE TABLE IF NOT EXISTS public.migration_mirror_runs (
  id            uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id     uuid NOT NULL,
  ran_at        timestamptz NOT NULL DEFAULT now(),
  mode          text,
  written       int,
  pending_after int,
  ok            boolean NOT NULL DEFAULT true,
  note          text
);

CREATE INDEX IF NOT EXISTS idx_migration_mirror_runs_agency_ran
  ON public.migration_mirror_runs (agency_id, ran_at DESC);

ALTER TABLE public.migration_mirror_runs ENABLE ROW LEVEL SECURITY;

-- Seed one row so the staleness check does not fire on its first evaluation
-- before any run has had the chance to record itself.
INSERT INTO public.migration_mirror_runs (agency_id, mode, written, pending_after, ok, note)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'seed', 0, 0, true,
       'seeded at install so the 26h staleness check has a baseline'
WHERE NOT EXISTS (
  SELECT 1 FROM public.migration_mirror_runs
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
);

CREATE OR REPLACE FUNCTION public.run_migration_mirror_nightly(
  p_agency_id uuid,
  p_recipe_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net
AS $fn$
DECLARE
  v_secret   text;
  v_svc_key  text;
  v_req      bigint;
  v_last_ok  timestamptz;
  v_stalled  boolean := false;
BEGIN
  SELECT setting_value INTO v_secret
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'automation_runner_cron_secret';

  IF v_secret IS NULL THEN
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary', 'skipped: automation_runner_cron_secret not set');
  END IF;

  SELECT setting_value INTO v_svc_key
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'supabase_service_role_key';

  -- Staleness check on the PREVIOUS run, before dispatching this one.
  SELECT max(ran_at) INTO v_last_ok
  FROM public.migration_mirror_runs
  WHERE agency_id = p_agency_id AND ok;

  IF v_last_ok IS NULL OR v_last_ok < now() - interval '26 hours' THEN
    v_stalled := true;
    -- One open alert at a time; do not restack every night.
    IF NOT EXISTS (
      SELECT 1 FROM public.alerts
      WHERE agency_id = p_agency_id
        AND alert_type = 'migration_mirror_stalled'
        AND is_resolved = false
    ) THEN
      INSERT INTO public.alerts
        (agency_id, alert_type, severity, title, message,
         module_reference, is_read, is_resolved)
      VALUES (
        p_agency_id, 'migration_mirror_stalled', 'warning',
        'Migration mirror has not completed a run in over 26 hours',
        format('Last successful run: %s. The nightly dispatch is rejected at the gateway when it collides with an edge-function redeploy, and such a rejection cannot self-report. Check migration_mirror_runs and run a manual backfill.',
               coalesce(v_last_ok::text, 'never')),
        'migration-mirror', false, false);
    END IF;
  END IF;

  -- Authorization header is what stops the deploy-window 401. Body still
  -- carries shared_secret; the function still checks it.
  SELECT net.http_post(
    url     := 'https://vulhdujhbwvibbojiimi.supabase.co/functions/v1/migration-mirror',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || coalesce(v_svc_key, '')),
    body    := jsonb_build_object(
                 'agency_id',     p_agency_id,
                 'shared_secret', v_secret,
                 'mode',          'backfill',
                 'branch',        'db',
                 'limit',         50,
                 'max_batches',   6),
    timeout_milliseconds := 300000
  ) INTO v_req;

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format('migration-mirror dispatched (pg_net request %s)%s',
                             v_req,
                             CASE WHEN v_stalled THEN ' — STALL ALERT RAISED' ELSE '' END));
END;
$fn$;

REVOKE ALL ON FUNCTION public.run_migration_mirror_nightly(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.run_migration_mirror_nightly(uuid, uuid) TO service_role;
