-- One-sided shrinkage (Peter decision 2026-08-14): an untrusted protocol may never
-- RAISE a candidate's standing. Scores above the 50 anchor still regress toward 50
-- (Kelley 1927; Nunnally & Bernstein 1994) -- that is where faking-good inflation
-- lives, since faking distorts upward by definition and elevated-IM protocols cluster
-- above the mean. Scores at or below 50 now hold their observed value instead of
-- drifting up toward the anchor. This is a documented SELECTION-POLICY modification of
-- the textbook symmetric estimator, not a claim of better score recovery: the
-- asymmetric loss is that a lifted low score can cross an advance threshold and cost
-- an interview on an untrustworthy protocol, while leaving a possibly-too-low estimate
-- on a below-average scorer costs nothing in a selection context. Individual score
-- "correction" (subtracting an estimated faking amount) remains off the table per
-- Ellingson, Sackett & Hough 1999. Revisit alongside the multiplier recalibration at
-- N=50 completed assessments.
-- Because the formula has exactly one home (single-source refactor, same day), this
-- change propagates automatically to character parts, assessment_character,
-- assessment_commitment, verdict_assessment, verdict_overall, the board view, and the
-- interview gap triggers with no other edits.

CREATE OR REPLACE FUNCTION public._newtworks_shrink(p_score numeric, p_v numeric)
RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE WHEN p_score IS NULL THEN NULL
              ELSE LEAST(p_score,
                         round(COALESCE(p_v, 1.0) * p_score
                               + (1 - COALESCE(p_v, 1.0)) * 50, 2))
         END;
$$;
