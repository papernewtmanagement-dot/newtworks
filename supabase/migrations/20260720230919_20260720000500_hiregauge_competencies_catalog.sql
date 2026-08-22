-- HireGauge competency catalog: source of truth for what competencies exist,
-- their human-readable names, and their LSS (speed/accuracy) sensitivity weights.
-- Weights nullable — populated in a follow-up step after review.

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
