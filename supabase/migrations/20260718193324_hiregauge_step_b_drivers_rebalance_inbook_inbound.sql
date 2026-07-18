-- Step B of HireGauge accuracy audit fix sequence.
-- Rebalance cts_drivers_assessment_cell for In-Book + Inbound to a symmetric
-- (DM + RD + CO×0.5) / 25 shape. Rationale: prior In-Book formula weighted
-- DM×0.5 + RD + CO (unequal); prior Inbound formula was (DM+RD)/20 with no CO
-- component. New shape gives full weight to Deadline Motivation and Recognition
-- Drive, half weight to Compassion (still dampened against response distortion),
-- denominator 25 matches the new coefficient sum. Default branch (5 other roles)
-- unchanged: (DM + RD + IS) / 30. Additive to op-rule
-- "Drivers-Assess formula rationale per role".
--
-- Cohort impact: Priscilla In-Book drivers 6.14 → 7.34, lifts her In-Book
-- composite out of last place. Non-additive change.

CREATE OR REPLACE FUNCTION public.cts_drivers_assessment_cell(
  p_assessment_id uuid,
  p_best_fit_role text
)
RETURNS numeric
LANGUAGE sql
STABLE
AS $function$
  SELECT CASE p_best_fit_role
    WHEN 'sales_inbound' THEN
      (COALESCE(ta.deadline_motivation, 0)
       + COALESCE(ta.recognition_drive, 0)
       + COALESCE(public._cts_dampen_trait_by_distortion(ta.compassion, 'compassion', ta.response_distortion), 0) * 0.5
      )::numeric / 25.0
    WHEN 'sales_in_book' THEN
      (COALESCE(ta.deadline_motivation, 0)
       + COALESCE(ta.recognition_drive, 0)
       + COALESCE(public._cts_dampen_trait_by_distortion(ta.compassion, 'compassion', ta.response_distortion), 0) * 0.5
      )::numeric / 25.0
    ELSE
      (COALESCE(ta.deadline_motivation, 0)
       + COALESCE(ta.recognition_drive, 0)
       + COALESCE(ta.independent_spirit, 0))::numeric / 30.0
  END
  FROM public.hiring_candidates ta
  WHERE ta.id = p_assessment_id;
$function$;
