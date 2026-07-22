-- Single source of truth for verdict thresholds. One row per layer + framework.
-- RPC + docs both read from here; hardcoded numbers get removed from the RPC.
CREATE TABLE IF NOT EXISTS public.hiregauge_verdict_thresholds (
  layer text PRIMARY KEY,
  pass_threshold numeric NOT NULL CHECK (pass_threshold > 0 AND pass_threshold <= 100),
  consider_threshold numeric NOT NULL CHECK (consider_threshold > 0 AND consider_threshold <= 100),
  notes text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (pass_threshold > consider_threshold)
);

INSERT INTO public.hiregauge_verdict_thresholds (layer, pass_threshold, consider_threshold, notes) VALUES
  ('resume',     70, 50, 'Resume layer — softer bar than other layers. 70+ pass, 50-69 consider, <50 decline.'),
  ('assessment', 75, 60, 'Assessment layer — role-fit-weighted CTS composite. 75+ pass, 60-74 consider, <60 decline.'),
  ('interview',  75, 60, 'Interview layer — composite of nature/nurture/drivers scored from interview_answers. 75+ pass, 60-74 consider, <60 decline. Character-floor probe RED overrides to decline_character regardless of composite.'),
  ('reference',  75, 60, 'Reference layer — weighted average of nature/nurture/drivers from reference calls. 75+ pass, 60-74 consider, <60 decline.'),
  ('framework',  75, 60, 'Overall framework verdict across all 4 layers. 75+ hire, 60-74 consider, <60 decline. Character-floor failed status overrides to decline_character.')
ON CONFLICT (layer) DO UPDATE SET
  pass_threshold = EXCLUDED.pass_threshold,
  consider_threshold = EXCLUDED.consider_threshold,
  notes = EXCLUDED.notes,
  updated_at = now();

-- Helper: score → verdict for a given layer. Reads from hiregauge_verdict_thresholds.
-- Returns 'not_scored' | 'pass' | 'consider' | 'decline'. Caller substitutes 'pass' → 'hire'
-- for framework-level verdict where the naming convention differs.
CREATE OR REPLACE FUNCTION public._hiregauge_layer_verdict(p_layer text, p_score numeric)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN p_score IS NULL THEN 'not_scored'
    WHEN p_score >= t.pass_threshold THEN 'pass'
    WHEN p_score >= t.consider_threshold THEN 'consider'
    ELSE 'decline'
  END
  FROM public.hiregauge_verdict_thresholds t
  WHERE t.layer = p_layer;
$$;
