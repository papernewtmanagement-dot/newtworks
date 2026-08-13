-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-09 02:15:24 UTC (ledger name: pool_pct_back_to_42_lock) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260709021524.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
UPDATE public.team_comp_pool_schedule
SET pool_pct = ROUND((pool_pct * 42.0 / 41.0)::numeric, 5)
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.team_comp_pool_schedule
SET plan_note = 'Week 1 rollout (42% anchor, LOCKED 2026-07-08 pending rebalance before final payroll); SMVC-stripped basis (~$533K annualized Q1/Q2 2026 pace)'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND week_end_date = '2026-07-11';

UPDATE public.team_comp_pool_schedule
SET plan_note = 'Bridge start; pool_pct lifted to hold envelope $/wk constant across AA28 Auto rate compression (~9.5% basis compression). 42% anchor as of 2026-07-08. RECOMPUTE late 2027 when SF finalizes AA28 VC mechanics.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND week_end_date = '2028-01-01';

UPDATE public.team_comp_pool_schedule
SET plan_note = 'Phase 3 end; mature steady state (42% anchor as of 2026-07-08). Post-2028 extension deferred.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND week_end_date = '2028-12-30';
