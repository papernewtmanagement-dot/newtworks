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
-- Speed thresholds unchanged - they are pool-independent (seconds per item).

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
  AND setting_key='hiregauge_lss_subtest_thresholds_v1';
