-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-08 21:56:13 UTC (ledger name: pool_pct_43_proportional_rescale) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260708215613.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Rescale pool_pct schedule from 50% anchor to 43% anchor (× 0.86)
-- Preserves ramp shape: Phase 1 linear rampdown, bridge lift, Phase 3 linear rampdown
-- Old anchors: 50% Week 1 → 45% Week 77 | bridge to 49.75% Week 78 → 40% Week 130
-- New anchors: 43% Week 1 → 38.70% Week 77 | bridge to 42.785% Week 78 → 34.40% Week 130

UPDATE public.team_comp_pool_schedule
SET pool_pct = ROUND((pool_pct * 0.86)::numeric, 5)
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- Update plan_note on anchor rows to reflect the new anchor values
UPDATE public.team_comp_pool_schedule
SET plan_note = 'Week 1 rollout start (43% anchor, rescaled 2026-07-08); SMVC-stripped basis (~$533K annualized Q1/Q2 2026 pace)'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND week_end_date = '2026-07-11';

UPDATE public.team_comp_pool_schedule
SET plan_note = 'Phase 1 end; bridge to AA28 next week (rescaled 2026-07-08)'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND week_end_date = '2027-12-25';

UPDATE public.team_comp_pool_schedule
SET plan_note = 'Bridge start; pool_pct lifted 38.70% -> 42.785% to hold envelope $/wk constant across AA28 Auto rate compression (assumes ~9.5% basis compression). Rescaled 2026-07-08 from 45%->49.75% original bridge. RECOMPUTE late 2027 when SF finalizes AA28 VC mechanics.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND week_end_date = '2028-01-01';

UPDATE public.team_comp_pool_schedule
SET plan_note = 'Phase 3 end; mature steady state 34.40% (rescaled 2026-07-08 from 40%). Post-2028 extension deferred.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND week_end_date = '2028-12-30';
