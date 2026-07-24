-- Batch 6 (orphans) LSS per-competency weight calibration.
-- Refines dials_cold_calls (verbal-lean off math) and prospects_in_community (verbal_acc dominant).
-- handles_rejection preserved (very light LSS influence — resilience isn't cognitively-measured).

UPDATE public.hiregauge_competencies
SET lss_config = jsonb_build_object(
  'weights', jsonb_build_object(
    'ps_acc', 0.05, 'ps_spd', 0.15,
    'math_acc', 0.03, 'math_spd', 0.10,
    'verbal_acc', 0.07, 'verbal_spd', 0.15,
    'acc_aggregate', 0.15, 'spd_aggregate', 0.40
  )
),
updated_at = NOW()
WHERE competency = 'dials_cold_calls';

UPDATE public.hiregauge_competencies
SET lss_config = jsonb_build_object(
  'weights', jsonb_build_object(
    'ps_acc', 0.05, 'ps_spd', 0.05,
    'math_acc', 0.03, 'math_spd', 0.03,
    'verbal_acc', 0.22, 'verbal_spd', 0.12,
    'acc_aggregate', 0.30, 'spd_aggregate', 0.20
  )
),
updated_at = NOW()
WHERE competency = 'prospects_in_community';

-- handles_rejection: preserved (07-20 default was already clinically light-influence)

SELECT competency,
  (lss_config->'weights'->>'acc_aggregate')::numeric AS acc_agg,
  (lss_config->'weights'->>'spd_aggregate')::numeric AS spd_agg
FROM public.hiregauge_competencies
WHERE competency IN ('handles_rejection','dials_cold_calls','prospects_in_community');
