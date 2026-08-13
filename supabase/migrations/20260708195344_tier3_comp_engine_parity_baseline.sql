-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-08 19:53:44 UTC (ledger name: tier3_comp_engine_parity_baseline) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260708195344.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Ephemeral audit table so I can compare pre-refactor vs post-refactor comp engine outputs.
-- Dropped at end of Tier 3 comp engine session.
CREATE TABLE IF NOT EXISTS public._tier3_comp_parity (
  id SERIAL PRIMARY KEY,
  fn TEXT NOT NULL,
  captured_at TIMESTAMPTZ DEFAULT NOW(),
  phase TEXT NOT NULL,  -- 'baseline' or 'post-refactor'
  payload JSONB NOT NULL
);

INSERT INTO public._tier3_comp_parity (fn, phase, payload)
SELECT 'compute_pool_carveouts', 'baseline',
  public.compute_pool_carveouts('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-07-04'::date);

INSERT INTO public._tier3_comp_parity (fn, phase, payload)
SELECT 'compute_weekly_comp_residual_pool', 'baseline',
  jsonb_agg(to_jsonb(cwcrp.*) ORDER BY cwcrp.team_member_id)
FROM public.compute_weekly_comp_residual_pool(
  '126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-07-04'::date
) cwcrp;
