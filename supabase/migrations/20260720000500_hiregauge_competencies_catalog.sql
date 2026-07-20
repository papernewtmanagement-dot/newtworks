-- HireGauge competency catalog: source of truth for what competencies exist
-- across all seven role scoring functions, their human-readable names, and
-- their LSS (speed/accuracy test) sensitivity weights.
--
-- Purpose: replaces v4's hardcoded per-competency weights with a single
-- table read from by all seven cts_*_competencies_adjusted functions.
-- Same competency name = same weights everywhere. Tune in one place.
--
-- Weight scale: 0.00 to 1.00. Applied as a fraction of the ±15-point
-- maximum LSS swing. Sum of acc + spd weights = candidate's maximum
-- swing amplitude as a fraction of full 15pt lift/drop.
--
-- Extreme rows:
--   Handles Objections           1.00 / 1.00 (max cognitive combat)
--   Handles Rejection            0.10 / 0.15 (emotional, not cognitive)

CREATE TABLE IF NOT EXISTS public.hiregauge_competencies (
  competency      text PRIMARY KEY,
  display_name    text NOT NULL,
  lss_acc_weight  numeric,
  lss_spd_weight  numeric,
  notes           text,
  updated_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.hiregauge_competencies ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS hiregauge_competencies_read ON public.hiregauge_competencies;
CREATE POLICY hiregauge_competencies_read
  ON public.hiregauge_competencies
  FOR SELECT
  USING (true);

DROP POLICY IF EXISTS hiregauge_competencies_write ON public.hiregauge_competencies;
CREATE POLICY hiregauge_competencies_write
  ON public.hiregauge_competencies
  FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- Seed 27 competencies with final-state LSS weights.
-- Idempotent via ON CONFLICT: safe to re-run against a partial catalog.
INSERT INTO public.hiregauge_competencies
  (competency, display_name, lss_acc_weight, lss_spd_weight) VALUES
  ('handles_objections',                     'Handles Objections',                       1.00, 1.00),
  ('makes_decisions_quickly',                'Makes Decisions Quickly',                  0.60, 0.90),
  ('routing_judgment',                       'Routing Judgment',                         0.70, 0.80),
  ('analytical',                             'Analytical',                               0.90, 0.60),
  ('is_fast_start_oriented',                 'Is Fast-Start Oriented',                   0.50, 0.90),
  ('presents_solutions',                     'Presents Solutions',                       0.90, 0.50),
  ('pivots_to_customer_need',                'Pivots to Customer Need',                  0.70, 0.70),
  ('composure_under_load',                   'Composure Under Load',                     0.60, 0.80),
  ('rapid_rapport_warm',                     'Rapid Rapport (Warm)',                     0.40, 0.80),
  ('queue_throughput_discipline',            'Queue Throughput Discipline',              0.30, 0.90),
  ('manages_time_effectively',               'Manages Time Effectively',                 0.50, 0.70),
  ('attention_to_detail',                    'Attention to Detail',                      1.00, 0.20),
  ('cross_sell_instinct',                    'Cross-Sell Instinct',                      0.70, 0.40),
  ('retention_watchfulness',                 'Retention Watchfulness',                   0.80, 0.30),
  ('works_without_close_supervision',        'Works Without Close Supervision',          0.50, 0.50),
  ('listens_discovers_needs',                'Listens and Discovers Needs',              0.80, 0.10),
  ('proactive_touch_discipline',             'Proactive Touch Discipline',               0.30, 0.60),
  ('cadence_compliance',                     'Cadence Compliance',                       0.30, 0.60),
  ('balances_logic_and_emotion_when_hiring', 'Balances Logic and Emotion When Hiring',   0.50, 0.20),
  ('receives_coaching',                      'Receives Coaching',                        0.50, 0.15),
  ('maintains_high_activity',                'Maintains High Activity',                  0.15, 0.40),
  ('dials_cold_calls',                       'Dials Cold Calls',                         0.15, 0.40),
  ('competes_for_recognition',               'Competes for Recognition',                 0.20, 0.30),
  ('prospects_in_community',                 'Prospects in Community',                   0.30, 0.20),
  ('positively_influences_team',             'Positively Influences Team',               0.20, 0.30),
  ('has_entrepreneurial_spirit',             'Has Entrepreneurial Spirit',               0.15, 0.25),
  ('handles_rejection',                      'Handles Rejection',                        0.10, 0.15)
ON CONFLICT (competency) DO UPDATE
  SET display_name   = EXCLUDED.display_name,
      lss_acc_weight = EXCLUDED.lss_acc_weight,
      lss_spd_weight = EXCLUDED.lss_spd_weight,
      updated_at     = now();
