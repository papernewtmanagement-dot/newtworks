-- Add 6 columns to hiring_candidates to store output of score-resume-rubric edge fn.
-- All nullable — existing 79 rows stay valid. No index needed at current volume.

ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS res_composite     NUMERIC(3,2),
  ADD COLUMN IF NOT EXISTS res_verdict       TEXT,
  ADD COLUMN IF NOT EXISTS res_subsignals    JSONB,
  ADD COLUMN IF NOT EXISTS res_rules_fired   TEXT[],
  ADD COLUMN IF NOT EXISTS res_scored_at     TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS res_scored_model  TEXT;

-- Verdict allowed values (nullable = not yet scored)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'hiring_candidates_res_verdict_check'
  ) THEN
    ALTER TABLE public.hiring_candidates
      ADD CONSTRAINT hiring_candidates_res_verdict_check
      CHECK (res_verdict IS NULL OR res_verdict IN ('pass','consider','decline'));
  END IF;
END$$;

-- Composite range guard (0.00 - 10.00)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'hiring_candidates_res_composite_check'
  ) THEN
    ALTER TABLE public.hiring_candidates
      ADD CONSTRAINT hiring_candidates_res_composite_check
      CHECK (res_composite IS NULL OR (res_composite >= 0 AND res_composite <= 10));
  END IF;
END$$;

COMMENT ON COLUMN public.hiring_candidates.res_composite
  IS 'Weighted composite score 0.00-10.00. Computed by score-resume-rubric edge fn.';
COMMENT ON COLUMN public.hiring_candidates.res_verdict
  IS 'pass (>=7.0) | consider (5.0-6.99) | decline (<5.0). Set by score-resume-rubric.';
COMMENT ON COLUMN public.hiring_candidates.res_subsignals
  IS 'JSONB with 9 keys, one per sub-signal. Each: {score: 1-10, reasoning: text}.';
COMMENT ON COLUMN public.hiring_candidates.res_rules_fired
  IS 'Array of hiregauge_rules.short_label for resume_screen_signal rules that matched. Informational only, no composite effect.';
COMMENT ON COLUMN public.hiring_candidates.res_scored_at
  IS 'Timestamp of last scoring pass. Presence = scored; scoring is idempotent-skipped when set unless explicit re-score.';
COMMENT ON COLUMN public.hiring_candidates.res_scored_model
  IS 'Groq model used for this scoring pass (e.g. openai/gpt-oss-120b). Enables re-score audit if model version changes.';
