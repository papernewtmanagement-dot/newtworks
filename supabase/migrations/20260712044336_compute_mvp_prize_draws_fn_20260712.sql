-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-12 04:43:36 UTC (ledger name: compute_mvp_prize_draws_fn_20260712) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260712044336.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Look up the draws-count for a given weekly new SP value from mvp_draw_tiers.
-- Returns the DRAWS count of the highest tier whose min_new_sp <= new_sp. Returns 0 if below all.
CREATE OR REPLACE FUNCTION public.compute_mvp_prize_draws(p_agency_id uuid, p_new_sp numeric)
RETURNS int
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  SELECT COALESCE(
    (SELECT draws FROM public.mvp_draw_tiers
      WHERE agency_id = p_agency_id
        AND min_new_sp <= p_new_sp
      ORDER BY min_new_sp DESC LIMIT 1),
    0
  );
$$;

-- Verify with handbook tiers: 99 -> 0, 100 -> 1, 299 -> 1, 300 -> 2, 499 -> 2, 500 -> 3, 1000 -> 3
SELECT
  public.compute_mvp_prize_draws('126794dd-25ff-47d2-a436-724499733365',99) AS at99,
  public.compute_mvp_prize_draws('126794dd-25ff-47d2-a436-724499733365',100) AS at100,
  public.compute_mvp_prize_draws('126794dd-25ff-47d2-a436-724499733365',299) AS at299,
  public.compute_mvp_prize_draws('126794dd-25ff-47d2-a436-724499733365',300) AS at300,
  public.compute_mvp_prize_draws('126794dd-25ff-47d2-a436-724499733365',500) AS at500,
  public.compute_mvp_prize_draws('126794dd-25ff-47d2-a436-724499733365',1000) AS at1000;
