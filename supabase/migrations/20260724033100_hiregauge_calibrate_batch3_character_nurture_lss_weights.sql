-- Batch 3 (character/nurture): calibrate per-subtest LSS weights for 5 competencies.
-- Nurture construct competencies are personality-heavy; LSS carries lighter weight
-- than for job-execution competencies. All positive weights this batch.

UPDATE public.hiregauge_competencies
SET lss_config = '{"weights":{"verbal_acc":0.15,"math_acc":0.05,"ps_acc":0.05,"verbal_spd":0.05,"math_spd":0.05,"ps_spd":0.05,"acc_aggregate":0.25,"spd_aggregate":0.15}}'::jsonb
WHERE competency = 'receives_coaching';

UPDATE public.hiregauge_competencies
SET lss_config = '{"weights":{"verbal_acc":0.20,"math_acc":0.05,"ps_acc":0.05,"verbal_spd":0.10,"math_spd":0.05,"ps_spd":0.05,"acc_aggregate":0.30,"spd_aggregate":0.20}}'::jsonb
WHERE competency = 'positively_influences_team';

UPDATE public.hiregauge_competencies
SET lss_config = '{"weights":{"verbal_acc":0.10,"math_acc":0.05,"ps_acc":0.10,"verbal_spd":0.15,"math_spd":0.10,"ps_spd":0.15,"acc_aggregate":0.25,"spd_aggregate":0.40}}'::jsonb
WHERE competency = 'competes_for_recognition';

UPDATE public.hiregauge_competencies
SET lss_config = '{"weights":{"verbal_acc":0.10,"math_acc":0.15,"ps_acc":0.20,"verbal_spd":0.05,"math_spd":0.05,"ps_spd":0.10,"acc_aggregate":0.45,"spd_aggregate":0.20}}'::jsonb
WHERE competency = 'works_without_close_supervision';

UPDATE public.hiregauge_competencies
SET lss_config = '{"weights":{"verbal_acc":0.10,"math_acc":0.10,"ps_acc":0.20,"verbal_spd":0.10,"math_spd":0.10,"ps_spd":0.15,"acc_aggregate":0.40,"spd_aggregate":0.35}}'::jsonb
WHERE competency = 'has_entrepreneurial_spirit';
