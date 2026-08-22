-- Batch 4 (throughput): calibrate per-subtest LSS weights for 5 competencies.
-- All speed-heavy — this batch measures pace, discipline, execution rate.

UPDATE public.hiregauge_competencies
SET lss_config = '{"weights":{"verbal_acc":0.10,"math_acc":0.10,"ps_acc":0.10,"verbal_spd":0.20,"math_spd":0.20,"ps_spd":0.20,"acc_aggregate":0.30,"spd_aggregate":0.60}}'::jsonb
WHERE competency = 'cadence_compliance';

UPDATE public.hiregauge_competencies
SET lss_config = '{"weights":{"verbal_acc":0.15,"math_acc":0.05,"ps_acc":0.10,"verbal_spd":0.20,"math_spd":0.15,"ps_spd":0.20,"acc_aggregate":0.30,"spd_aggregate":0.55}}'::jsonb
WHERE competency = 'proactive_touch_discipline';

UPDATE public.hiregauge_competencies
SET lss_config = '{"weights":{"verbal_acc":0.05,"math_acc":0.05,"ps_acc":0.15,"verbal_spd":0.20,"math_spd":0.20,"ps_spd":0.30,"acc_aggregate":0.25,"spd_aggregate":0.70}}'::jsonb
WHERE competency = 'is_fast_start_oriented';

UPDATE public.hiregauge_competencies
SET lss_config = '{"weights":{"verbal_acc":0.10,"math_acc":0.10,"ps_acc":0.20,"verbal_spd":0.15,"math_spd":0.10,"ps_spd":0.30,"acc_aggregate":0.40,"spd_aggregate":0.55}}'::jsonb
WHERE competency = 'makes_decisions_quickly';

UPDATE public.hiregauge_competencies
SET lss_config = '{"weights":{"verbal_acc":0.10,"math_acc":0.15,"ps_acc":0.20,"verbal_spd":0.10,"math_spd":0.15,"ps_spd":0.15,"acc_aggregate":0.45,"spd_aggregate":0.40}}'::jsonb
WHERE competency = 'manages_time_effectively';
