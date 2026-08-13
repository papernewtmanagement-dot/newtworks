-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-10 22:41:37 UTC (ledger name: drop_pg_net_polling_layer_v2) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260710224137.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- 2026-07-10: Second retirement of the pg_net polling layer.
-- Original retirement 2026-06-19 per op-rule "Newtworks dispatch_* recipe
-- convention — direct fetch from automation-runner, no pg_net". Somewhere
-- between then and now these two SQL functions were recreated, and the
-- runner was rewired to poll them via pg_net + get_pg_net_response. That
-- polling path was silently reporting fake success for all dispatched-
-- edge-fn recipes because PostgREST cannot reliably read
-- net._http_response.
--
-- v42 of the runner (deployed 2026-07-10) removed the polling block and
-- restored the direct-fetch pattern. These SQL functions are unreachable
-- and must not exist per the architectural rule.

DROP FUNCTION IF EXISTS public.dispatch_document_processor(uuid, uuid);
DROP FUNCTION IF EXISTS public.get_pg_net_response(bigint);

-- Verify neither exists after drop (fail loudly if they do)
DO $verify$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('dispatch_document_processor', 'get_pg_net_response')
  ) THEN
    RAISE EXCEPTION 'Retired SQL functions still exist after DROP — migration integrity failure.';
  END IF;
END;
$verify$;
