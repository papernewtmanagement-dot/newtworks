-- 20260724021104_hiregauge_lss_per_competency_config_foundation.sql
-- Per-competency LSS architecture foundation.
--
-- Adds hiregauge_competencies.lss_config jsonb column, seeds a global
-- settings row 'hiregauge_lss_subtest_thresholds' with the neutral/target
-- thresholds each subtest is scored against, and backfills lss_config for
-- all 27 competency rows.
--
-- The 6 rows subsequently calibrated in this session (handles_objections,
-- attention_to_detail, maintains_high_activity, listens_discovers_needs,
-- analytical, presents_solutions) are seeded here with their final
-- calibrated weights; the 021132 + 022206 UPDATE migrations idempotently
-- restate those same values.
--
-- The remaining 21 rows carry placeholder splits derived from the prior
-- aggregate lss_acc_weight/lss_spd_weight values (weights fan out
-- proportionally across the three accuracy subtests and the three speed
-- subtests). Placeholder rows still call the per-subtest primitive
-- correctly but are pending per-competency calibration in follow-on
-- batches.

ALTER TABLE public.hiregauge_competencies
  ADD COLUMN IF NOT EXISTS lss_config jsonb;

-- Global default per-subtest thresholds (neutral = pass floor, target = excellence)
INSERT INTO public.settings (agency_id, setting_key, setting_value)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'hiregauge_lss_subtest_thresholds',
  '{"ps_acc_target": 10, "ps_spd_target": 25, "ps_acc_neutral": 7, "ps_spd_neutral": 77, "math_acc_target": 11, "math_spd_target": 18, "math_acc_neutral": 10, "math_spd_neutral": 50, "verbal_acc_target": 12, "verbal_spd_target": 15, "verbal_acc_neutral": 8, "verbal_spd_neutral": 52}'
)
ON CONFLICT (agency_id, setting_key) DO UPDATE
  SET setting_value = EXCLUDED.setting_value;

-- Backfill lss_config for all 27 competencies.

-- CALIBRATED ROWS (6) — session batch 1
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.35,"math_acc":0.05,"ps_acc":0.20,"verbal_spd":0.15,"math_spd":0.05,"ps_spd":0.20,"acc_aggregate":0.60,"spd_aggregate":0.40}}'::jsonb WHERE competency='handles_objections';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.30,"math_acc":0.30,"ps_acc":0.20,"verbal_spd":-0.05,"math_spd":-0.05,"ps_spd":-0.10,"acc_aggregate":0.80,"spd_aggregate":-0.20}}'::jsonb WHERE competency='attention_to_detail';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.05,"math_acc":0.05,"ps_acc":0.10,"verbal_spd":0.25,"math_spd":0.25,"ps_spd":0.30,"acc_aggregate":0.20,"spd_aggregate":0.80}}'::jsonb WHERE competency='maintains_high_activity';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.50,"math_acc":0.05,"ps_acc":0.15,"verbal_spd":0.10,"math_spd":0.05,"ps_spd":0.15,"acc_aggregate":0.70,"spd_aggregate":0.30}}'::jsonb WHERE competency='listens_discovers_needs';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.10,"math_acc":0.35,"ps_acc":0.35,"verbal_spd":0.05,"math_spd":0.10,"ps_spd":0.05,"acc_aggregate":0.80,"spd_aggregate":0.20}}'::jsonb WHERE competency='analytical';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.30,"math_acc":0.15,"ps_acc":0.20,"verbal_spd":0.15,"math_spd":0.10,"ps_spd":0.10,"acc_aggregate":0.65,"spd_aggregate":0.35}}'::jsonb WHERE competency='presents_solutions';

-- PLACEHOLDER ROWS (21) — split from prior aggregate weights, pending per-competency calibration
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.120,"math_acc":0.090,"ps_acc":0.090,"verbal_spd":0.067,"math_spd":0.067,"ps_spd":0.067,"acc_aggregate":0.30,"spd_aggregate":0.20}}'::jsonb WHERE competency='balances_logic_and_emotion_when_hiring';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.120,"math_acc":0.090,"ps_acc":0.090,"verbal_spd":0.200,"math_spd":0.200,"ps_spd":0.200,"acc_aggregate":0.30,"spd_aggregate":0.60}}'::jsonb WHERE competency='cadence_compliance';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.080,"math_acc":0.060,"ps_acc":0.060,"verbal_spd":0.100,"math_spd":0.100,"ps_spd":0.100,"acc_aggregate":0.20,"spd_aggregate":0.30}}'::jsonb WHERE competency='competes_for_recognition';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.240,"math_acc":0.180,"ps_acc":0.180,"verbal_spd":0.266,"math_spd":0.266,"ps_spd":0.267,"acc_aggregate":0.60,"spd_aggregate":0.80}}'::jsonb WHERE competency='composure_under_load';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.280,"math_acc":0.210,"ps_acc":0.210,"verbal_spd":0.133,"math_spd":0.133,"ps_spd":0.134,"acc_aggregate":0.70,"spd_aggregate":0.40}}'::jsonb WHERE competency='cross_sell_instinct';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.060,"math_acc":0.045,"ps_acc":0.045,"verbal_spd":0.133,"math_spd":0.133,"ps_spd":0.134,"acc_aggregate":0.15,"spd_aggregate":0.40}}'::jsonb WHERE competency='dials_cold_calls';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.040,"math_acc":0.030,"ps_acc":0.030,"verbal_spd":0.050,"math_spd":0.050,"ps_spd":0.050,"acc_aggregate":0.10,"spd_aggregate":0.15}}'::jsonb WHERE competency='handles_rejection';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.060,"math_acc":0.045,"ps_acc":0.045,"verbal_spd":0.083,"math_spd":0.083,"ps_spd":0.084,"acc_aggregate":0.15,"spd_aggregate":0.25}}'::jsonb WHERE competency='has_entrepreneurial_spirit';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.200,"math_acc":0.150,"ps_acc":0.150,"verbal_spd":0.300,"math_spd":0.300,"ps_spd":0.301,"acc_aggregate":0.50,"spd_aggregate":0.90}}'::jsonb WHERE competency='is_fast_start_oriented';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.240,"math_acc":0.180,"ps_acc":0.180,"verbal_spd":0.300,"math_spd":0.300,"ps_spd":0.301,"acc_aggregate":0.60,"spd_aggregate":0.90}}'::jsonb WHERE competency='makes_decisions_quickly';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.200,"math_acc":0.150,"ps_acc":0.150,"verbal_spd":0.233,"math_spd":0.233,"ps_spd":0.234,"acc_aggregate":0.50,"spd_aggregate":0.70}}'::jsonb WHERE competency='manages_time_effectively';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.280,"math_acc":0.210,"ps_acc":0.210,"verbal_spd":0.233,"math_spd":0.233,"ps_spd":0.234,"acc_aggregate":0.70,"spd_aggregate":0.70}}'::jsonb WHERE competency='pivots_to_customer_need';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.080,"math_acc":0.060,"ps_acc":0.060,"verbal_spd":0.100,"math_spd":0.100,"ps_spd":0.100,"acc_aggregate":0.20,"spd_aggregate":0.30}}'::jsonb WHERE competency='positively_influences_team';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.120,"math_acc":0.090,"ps_acc":0.090,"verbal_spd":0.200,"math_spd":0.200,"ps_spd":0.200,"acc_aggregate":0.30,"spd_aggregate":0.60}}'::jsonb WHERE competency='proactive_touch_discipline';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.120,"math_acc":0.090,"ps_acc":0.090,"verbal_spd":0.067,"math_spd":0.067,"ps_spd":0.067,"acc_aggregate":0.30,"spd_aggregate":0.20}}'::jsonb WHERE competency='prospects_in_community';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.120,"math_acc":0.090,"ps_acc":0.090,"verbal_spd":0.300,"math_spd":0.300,"ps_spd":0.301,"acc_aggregate":0.30,"spd_aggregate":0.90}}'::jsonb WHERE competency='queue_throughput_discipline';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.080,"math_acc":0.060,"ps_acc":0.060,"verbal_spd":0.266,"math_spd":0.266,"ps_spd":0.267,"acc_aggregate":0.20,"spd_aggregate":0.80}}'::jsonb WHERE competency='rapid_rapport_warm';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.080,"math_acc":0.060,"ps_acc":0.060,"verbal_spd":0.050,"math_spd":0.050,"ps_spd":0.050,"acc_aggregate":0.20,"spd_aggregate":0.15}}'::jsonb WHERE competency='receives_coaching';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.320,"math_acc":0.240,"ps_acc":0.240,"verbal_spd":0.100,"math_spd":0.100,"ps_spd":0.100,"acc_aggregate":0.80,"spd_aggregate":0.30}}'::jsonb WHERE competency='retention_watchfulness';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.280,"math_acc":0.210,"ps_acc":0.210,"verbal_spd":0.266,"math_spd":0.266,"ps_spd":0.267,"acc_aggregate":0.70,"spd_aggregate":0.80}}'::jsonb WHERE competency='routing_judgment';
UPDATE public.hiregauge_competencies SET lss_config = '{"weights":{"verbal_acc":0.080,"math_acc":0.060,"ps_acc":0.060,"verbal_spd":0.100,"math_spd":0.100,"ps_spd":0.100,"acc_aggregate":0.20,"spd_aggregate":0.30}}'::jsonb WHERE competency='works_without_close_supervision';
