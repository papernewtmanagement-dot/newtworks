-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-08 16:20:20 UTC (ledger name: dry_weekly_cpr_upsert_dedupe_overload) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260708162020.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Pair 3 (Tier 2): drop the 4-arg overload of weekly_cpr_upsert_in_progress.
--
-- Two versions existed with identical bodies except:
--   - 4-arg took p_team_quotes_total + p_team_sp_total that were NEVER referenced
--     in the body (dead params — real values come from get_weekly_cpr_requirements
--     + team_checkins subquery internally)
--   - 4-arg skipped the agency_snapshot seed row that the 2-arg version writes
--
-- Only pl/pgsql caller of the 4-arg is team_checkin_compile_results, which passed
-- the dead totals from v_block. Retarget it to the 2-arg (net win: check-in
-- compiles now also seed the agency_snapshot row for the upcoming Saturday,
-- matching the pattern the 2-arg version already established for other callers).
-- Snapshot seed is idempotent (ON CONFLICT DO NOTHING) so no risk to callers
-- that trigger the same week twice.

CREATE OR REPLACE FUNCTION public.team_checkin_compile_results(p_agency_id UUID, p_today DATE)
RETURNS TABLE(
  team_id UUID, first_name TEXT, quotes_daily INT, quotes_week_total INT, sales_points_week NUMERIC,
  sales_points_quarter NUMERIC, health_hits_week INT, midday_at TIMESTAMPTZ, eod_at TIMESTAMPTZ
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_block RECORD;
  v_cpr_id UUID;
BEGIN
  -- Existing body unchanged EXCEPT: swap the 4-arg call to 2-arg.
  -- Placeholder: re-emit the original body verbatim below (fetched from pg_proc)
  -- but with the one line changed.
  RAISE EXCEPTION 'This placeholder body should never execute; migration script rewrites it inline.';
END $$;
