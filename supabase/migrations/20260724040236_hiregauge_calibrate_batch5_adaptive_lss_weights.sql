-- Batch 5 (adaptive) LSS per-competency weight calibration.
-- Refines pivots_to_customer_need and composure_under_load away from 07-20 generic-uniform defaults
-- toward clinically-shaped weights (math near-zero for pivots; spd-leads-acc for composure).
-- rapid_rapport_warm and balances_logic_and_emotion_when_hiring preserved (07-21 refined values).

UPDATE public.hiregauge_competencies
SET lss_config = jsonb_build_object(
  'weights', jsonb_build_object(
    'ps_acc', 0.10, 'ps_spd', 0.20,
    'math_acc', 0.05, 'math_spd', 0.05,
    'verbal_acc', 0.25, 'verbal_spd', 0.25,
    'acc_aggregate', 0.40, 'spd_aggregate', 0.50
  )
),
updated_at = NOW()
WHERE competency = 'pivots_to_customer_need';

UPDATE public.hiregauge_competencies
SET lss_config = jsonb_build_object(
  'weights', jsonb_build_object(
    'ps_acc', 0.15, 'ps_spd', 0.25,
    'math_acc', 0.10, 'math_spd', 0.20,
    'verbal_acc', 0.20, 'verbal_spd', 0.30,
    'acc_aggregate', 0.45, 'spd_aggregate', 0.75
  )
),
updated_at = NOW()
WHERE competency = 'composure_under_load';

-- rapid_rapport_warm: preserved (07-21 refined values intentional)
-- balances_logic_and_emotion_when_hiring: preserved (07-21 refined values intentional)

-- Verify all 4 adaptive competencies present + inspect
SELECT competency,
  (lss_config->'weights'->>'acc_aggregate')::numeric AS acc_agg,
  (lss_config->'weights'->>'spd_aggregate')::numeric AS spd_agg
FROM public.hiregauge_competencies
WHERE competency IN ('pivots_to_customer_need','composure_under_load','rapid_rapport_warm','balances_logic_and_emotion_when_hiring');
