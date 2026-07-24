-- 20260724022206_hiregauge_calibrate_batch1_lss_weights.sql
-- Calibrate batch 1: 5 competencies with per-subtest LSS weights.
--
-- attention_to_detail: verbal + math + PS accuracy carry positive weight,
-- speeds carry NEGATIVE weight (fast HURTS this competency).
--
-- maintains_high_activity: speeds dominate, accuracies minimal.
--
-- listens_discovers_needs: verbal_acc dominant (0.50).
--
-- analytical: math + PS accuracy dominant; base is raw analytical trait
-- (no multi-trait regression — only competency where that's true).
--
-- presents_solutions: verbal accuracy + moderate speeds + PS + math.

UPDATE public.hiregauge_competencies
SET lss_config = '{"weights":{"verbal_acc":0.30,"math_acc":0.30,"ps_acc":0.20,"verbal_spd":-0.05,"math_spd":-0.05,"ps_spd":-0.10,"acc_aggregate":0.80,"spd_aggregate":-0.20}}'::jsonb
WHERE competency = 'attention_to_detail';

UPDATE public.hiregauge_competencies
SET lss_config = '{"weights":{"verbal_acc":0.05,"math_acc":0.05,"ps_acc":0.10,"verbal_spd":0.25,"math_spd":0.25,"ps_spd":0.30,"acc_aggregate":0.20,"spd_aggregate":0.80}}'::jsonb
WHERE competency = 'maintains_high_activity';

UPDATE public.hiregauge_competencies
SET lss_config = '{"weights":{"verbal_acc":0.50,"math_acc":0.05,"ps_acc":0.15,"verbal_spd":0.10,"math_spd":0.05,"ps_spd":0.15,"acc_aggregate":0.70,"spd_aggregate":0.30}}'::jsonb
WHERE competency = 'listens_discovers_needs';

UPDATE public.hiregauge_competencies
SET lss_config = '{"weights":{"verbal_acc":0.10,"math_acc":0.35,"ps_acc":0.35,"verbal_spd":0.05,"math_spd":0.10,"ps_spd":0.05,"acc_aggregate":0.80,"spd_aggregate":0.20}}'::jsonb
WHERE competency = 'analytical';

UPDATE public.hiregauge_competencies
SET lss_config = '{"weights":{"verbal_acc":0.30,"math_acc":0.15,"ps_acc":0.20,"verbal_spd":0.15,"math_spd":0.10,"ps_spd":0.10,"acc_aggregate":0.65,"spd_aggregate":0.35}}'::jsonb
WHERE competency = 'presents_solutions';
