-- 20260724021132_hiregauge_calibrate_handles_objections_lss_weights.sql
-- Calibrate handles_objections per-subtest LSS weights.
-- Language-under-pressure competency: verbal accuracy dominant, PS + PS-speed
-- carry meaningful signal (thinking-on-your-feet), math minimal.
UPDATE public.hiregauge_competencies
SET lss_config = '{"weights":{"verbal_acc":0.35,"math_acc":0.05,"ps_acc":0.20,"verbal_spd":0.15,"math_spd":0.05,"ps_spd":0.20,"acc_aggregate":0.60,"spd_aggregate":0.40}}'::jsonb
WHERE competency = 'handles_objections';
