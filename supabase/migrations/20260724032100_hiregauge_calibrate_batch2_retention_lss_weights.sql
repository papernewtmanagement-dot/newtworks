-- Batch 2 (retention): calibrate per-subtest LSS weights for 4 competencies.
--
-- retention_watchfulness: pattern recognition, PS accuracy dominant, speeds modest.
-- cross_sell_instinct: verbal accuracy dominant (hearing life-event signal), PS + verbal speed moderate.
-- routing_judgment: PS accuracy + PS speed dominant (rule-pattern + fast decision).
-- queue_throughput_discipline: speeds dominant, meaningful accuracy weight (rework eats throughput).
--
-- All positive weights this batch — none are "fast HURTS" competencies.

UPDATE public.hiregauge_competencies
SET lss_config = '{"weights":{"verbal_acc":0.25,"math_acc":0.20,"ps_acc":0.35,"verbal_spd":0.05,"math_spd":0.05,"ps_spd":0.10,"acc_aggregate":0.75,"spd_aggregate":0.25}}'::jsonb
WHERE competency = 'retention_watchfulness';

UPDATE public.hiregauge_competencies
SET lss_config = '{"weights":{"verbal_acc":0.40,"math_acc":0.10,"ps_acc":0.20,"verbal_spd":0.15,"math_spd":0.05,"ps_spd":0.10,"acc_aggregate":0.70,"spd_aggregate":0.30}}'::jsonb
WHERE competency = 'cross_sell_instinct';

UPDATE public.hiregauge_competencies
SET lss_config = '{"weights":{"verbal_acc":0.20,"math_acc":0.10,"ps_acc":0.30,"verbal_spd":0.15,"math_spd":0.05,"ps_spd":0.20,"acc_aggregate":0.60,"spd_aggregate":0.40}}'::jsonb
WHERE competency = 'routing_judgment';

UPDATE public.hiregauge_competencies
SET lss_config = '{"weights":{"verbal_acc":0.10,"math_acc":0.10,"ps_acc":0.15,"verbal_spd":0.20,"math_spd":0.20,"ps_spd":0.25,"acc_aggregate":0.35,"spd_aggregate":0.65}}'::jsonb
WHERE competency = 'queue_throughput_discipline';
