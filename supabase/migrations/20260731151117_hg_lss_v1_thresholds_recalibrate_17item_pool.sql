-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-31 15:11:17 UTC (ledger name: hg_lss_v1_thresholds_recalibrate_17item_pool) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260731151117.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Recalibrate v1 LSS accuracy thresholds for the current 17-item cognitive pool
-- (6 math, 5 problem_solving, 6 verbal per candidate under form rotation).
-- Prior thresholds were pool-size-inappropriate: neutrals 8-9 and targets 9-13 on
-- 6-item domains (impossible), and PS neutral=1 (nonsensically low). Perfect
-- cognitive scores were registering as below-neutral and producing false penalties
-- in every competency function that consumes the LSS delta.
--
-- New calibration:
--   neutral = 4/6 (67%) for verbal + math, 3/5 (60%) for problem_solving
--   target  = 6/6 for verbal + math, 5/5 for problem_solving (full mark)
-- Speed thresholds unchanged — they are pool-independent (seconds per item).

UPDATE public.settings
SET setting_value = jsonb_build_object(
  'verbal_acc_neutral', 4,  'verbal_acc_target', 6,
  'math_acc_neutral',   4,  'math_acc_target',   6,
  'ps_acc_neutral',     3,  'ps_acc_target',     5,
  'verbal_spd_neutral', 52, 'verbal_spd_target', 15,
  'math_spd_neutral',   50, 'math_spd_target',   18,
  'ps_spd_neutral',     77, 'ps_spd_target',     25
)::text,
    updated_at = NOW()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND setting_key='hiregauge_lss_subtest_thresholds_v1'
RETURNING setting_key, setting_value;
