-- =====================================================================
-- Phase 1a: LSS + validity helpers, scorecard columns
-- =====================================================================

-- Helper: validity severity (0.0 = clean, 1.0 = badly compromised)
CREATE OR REPLACE FUNCTION public._cts_validity_severity(
  p_reliability text,
  p_distortion text
) RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_distortion = 'high' THEN 1.0
    WHEN p_distortion = 'moderate' THEN 0.6
    WHEN p_reliability = 'low' THEN 0.8
    WHEN p_reliability = 'moderate' THEN 0.4
    ELSE 0.0
  END::numeric;
$$;

COMMENT ON FUNCTION public._cts_validity_severity(text, text) IS
'Returns 0.0 (clean) to 1.0 (badly compromised) based on CTS reliability + distortion. Used to scale Bob-mechanism trait dampening.';

-- Helper: Bob-mechanism trait dampening. Ceiling scores (>75) reduced up to 15 pts. Floors preserved.
CREATE OR REPLACE FUNCTION public._cts_dampen_trait(
  p_trait integer,
  p_reliability text,
  p_distortion text
) RETURNS integer
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_trait IS NULL THEN NULL
    WHEN p_trait > 75 THEN GREATEST(
      75,
      p_trait - (15 * public._cts_validity_severity(p_reliability, p_distortion))::int
    )
    ELSE p_trait
  END;
$$;

COMMENT ON FUNCTION public._cts_dampen_trait(integer, text, text) IS
'Bob-mechanism: dampens ceiling scores (>75) proportionally to validity severity. Floors (<=75) preserved. Reduces up to 15 points at severity=1.0.';

-- Helper: LSS modifier (multiplicative competency adjustment, range [-0.15, +0.15])
CREATE OR REPLACE FUNCTION public._cts_lss_modifier(
  p_lss_accuracy integer,
  p_lss_speed_avg integer
) RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $$
  WITH n AS (
    SELECT
      CASE
        WHEN p_lss_accuracy IS NULL THEN 0.5
        ELSE LEAST(1.0, GREATEST(0.0, p_lss_accuracy::numeric / 35.0))
      END AS acc_n,
      CASE
        WHEN p_lss_speed_avg IS NULL THEN 0.5
        ELSE 1.0 - LEAST(1.0, GREATEST(0.0, p_lss_speed_avg::numeric / 600.0))
      END AS speed_n
  )
  SELECT LEAST(0.15, GREATEST(-0.15, ((n.acc_n * 0.7 + n.speed_n * 0.3) - 0.5) * 0.30))
  FROM n;
$$;

COMMENT ON FUNCTION public._cts_lss_modifier(integer, integer) IS
'Returns multiplier in [-0.15, +0.15] for LSS-adjusting competency scores. 70/30 accuracy/speed weight. Max ±15% at extremes.';

-- =====================================================================
-- Scorecard columns on team_assessments (Nurture + Drivers + retrospective)
-- =====================================================================

-- Nurture (Character) — interview-scored 1-10 each
ALTER TABLE public.team_assessments ADD COLUMN IF NOT EXISTS char_honesty smallint CHECK (char_honesty BETWEEN 1 AND 10);
ALTER TABLE public.team_assessments ADD COLUMN IF NOT EXISTS char_hwe smallint CHECK (char_hwe BETWEEN 1 AND 10);
ALTER TABLE public.team_assessments ADD COLUMN IF NOT EXISTS char_persres smallint CHECK (char_persres BETWEEN 1 AND 10);
ALTER TABLE public.team_assessments ADD COLUMN IF NOT EXISTS char_concern smallint CHECK (char_concern BETWEEN 1 AND 10);

-- Drivers (Motivation) — interview-scored 1-10
ALTER TABLE public.team_assessments ADD COLUMN IF NOT EXISTS mot_level smallint CHECK (mot_level BETWEEN 1 AND 10);
ALTER TABLE public.team_assessments ADD COLUMN IF NOT EXISTS mot_type text CHECK (mot_type IN ('competitive','income','duty','recognition'));
ALTER TABLE public.team_assessments ADD COLUMN IF NOT EXISTS mot_attitude_sales smallint CHECK (mot_attitude_sales BETWEEN 1 AND 10);
ALTER TABLE public.team_assessments ADD COLUMN IF NOT EXISTS mot_own_products smallint CHECK (mot_own_products BETWEEN 1 AND 10);

-- Nature (interview-layer validation) — Vacation Role Play + Personal Presence
ALTER TABLE public.team_assessments ADD COLUMN IF NOT EXISTS rp_needs smallint CHECK (rp_needs BETWEEN 1 AND 10);
ALTER TABLE public.team_assessments ADD COLUMN IF NOT EXISTS rp_presentation smallint CHECK (rp_presentation BETWEEN 1 AND 10);
ALTER TABLE public.team_assessments ADD COLUMN IF NOT EXISTS rp_closing smallint CHECK (rp_closing BETWEEN 1 AND 10);
ALTER TABLE public.team_assessments ADD COLUMN IF NOT EXISTS rp_objection smallint CHECK (rp_objection BETWEEN 1 AND 10);
ALTER TABLE public.team_assessments ADD COLUMN IF NOT EXISTS personal_presence smallint CHECK (personal_presence BETWEEN 1 AND 10);

-- Resume — dimension of its own (light weight)
ALTER TABLE public.team_assessments ADD COLUMN IF NOT EXISTS resume_quality smallint CHECK (resume_quality BETWEEN 1 AND 10);

-- Retrospective override for hired-and-performing members
ALTER TABLE public.team_assessments ADD COLUMN IF NOT EXISTS retrospective_verdict_override text CHECK (retrospective_verdict_override IN ('pass','flag','fail_confirmed'));
ALTER TABLE public.team_assessments ADD COLUMN IF NOT EXISTS retrospective_notes text;
ALTER TABLE public.team_assessments ADD COLUMN IF NOT EXISTS retrospective_scored_at timestamptz;

-- Scorecard context marker
ALTER TABLE public.team_assessments ADD COLUMN IF NOT EXISTS scorecard_context text CHECK (scorecard_context IN ('pre_hire','retrospective','mixed'));

COMMENT ON COLUMN public.team_assessments.char_honesty IS 'Character floor: Honesty 1-10 (Suggs). Floor at 7. Interview-scored, ref-verified.';
COMMENT ON COLUMN public.team_assessments.retrospective_verdict_override IS 'Peter override for hired members: pass=performing well, flag=framework saw issue but working, fail_confirmed=framework was right, they were let go.';
COMMENT ON COLUMN public.team_assessments.scorecard_context IS 'Context of scorecard scores: pre_hire (interview-fresh), retrospective (post-hire based on observed reality), mixed (partial).';