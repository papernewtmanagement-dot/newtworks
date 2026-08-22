-- Nightly guard so the mirror gap can never reopen.
-- Handler signature is the one run_internal_recipe dispatches on:
--   handler(agency_id uuid, recipe_id uuid) RETURNS jsonb

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
  v_secret text;
  v_req    bigint;
BEGIN
  SELECT setting_value INTO v_secret
  FROM public.settings
  WHERE agency_id = p_agency_id
    AND setting_key = 'automation_runner_cron_secret';

  IF v_secret IS NULL THEN
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary', 'skipped: automation_runner_cron_secret not set');
  END IF;

  -- pg_net is fire-and-forget, so a failure here would be invisible. It does
  -- not need to be visible: migration-mirror writes an alert row itself when a
  -- run fails, which is the channel that actually gets read.
  SELECT net.http_post(
    url     := 'https://vulhdujhbwvibbojiimi.supabase.co/functions/v1/migration-mirror',
    headers := jsonb_build_object('Content-Type', 'application/json'),
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
    'output_summary', format('migration-mirror dispatched (pg_net request %s)', v_req));
END;
$fn$;

REVOKE ALL ON FUNCTION public.run_migration_mirror_nightly(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.run_migration_mirror_nightly(uuid, uuid) TO service_role;

-- Recipe row. NOTE: no companion pg_cron.job is created. A raw cron entry that
-- called the same function alongside an active recipe row is exactly the
-- double-dispatch bug that put every time-off request on the calendar twice.
INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description,
  trigger_type, cron_expression, timezone,
  composio_action, internal_handler, is_active
)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  'Migration mirror — nightly',
  'Mirrors any migration in the ledger that has no repo file into supabase/migrations on the db branch. Keeps a fresh clone able to rebuild production.',
  'cron', '15 3 * * *', 'America/Chicago',
  'INTERNAL', 'run_migration_mirror_nightly', true
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND recipe_name = 'Migration mirror — nightly'
);
