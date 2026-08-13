-- Resume scoring revamp: signal-level weights table
-- Approved spec: session_note "2026-08-12 — Resume scoring revamp: approved spec
-- (signal-level weights + LE anchors + autonomy imputation)"

CREATE TABLE IF NOT EXISTS public.hiregauge_resume_signal_weights (
  signal_key text PRIMARY KEY,
  weight numeric NOT NULL,
  notes text
);

ALTER TABLE public.hiregauge_resume_signal_weights ENABLE ROW LEVEL SECURITY;

CREATE POLICY anon_read_hiregauge_resume_signal_weights
  ON public.hiregauge_resume_signal_weights
  FOR SELECT
  TO authenticated
  USING (is_agency_admin());

INSERT INTO public.hiregauge_resume_signal_weights (signal_key, weight, notes) VALUES
  ('leadership_emergence',    0.200, NULL),
  ('goal_orientation',        0.200, NULL),
  ('trajectory_direction',    0.100, NULL),
  ('interpersonal_substrate', 0.100, NULL),
  ('hard_work_ethic',         0.080, NULL),
  ('follow_through',          0.080, NULL),
  ('coherent_pursuit',        0.080, NULL),
  ('autonomy',                0.060, NULL),
  ('honesty',                 0.050, NULL),
  ('concern_for_others',      0.025, NULL),
  ('personal_responsibility', 0.025, NULL),
  ('presentation',            0.000, 'display-only'),
  ('content_effort',          0.000, 'display-only')
ON CONFLICT (signal_key) DO NOTHING;
