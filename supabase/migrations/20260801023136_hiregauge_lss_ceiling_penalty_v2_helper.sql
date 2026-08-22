CREATE OR REPLACE FUNCTION public.hiregauge_lss_ceiling_penalty_v2(
  p_composite numeric,
  p_ceiling   numeric
)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $function$
/*
2d fit-side above-ceiling quadratic curve for LSS penalty multiplier.

  penalty_multiplier =
    1.0                                                              if p_composite IS NULL
    1.0                                                              if p_ceiling   IS NULL
    1.0                                                              if p_composite <= p_ceiling
    1.0                                                              if p_ceiling  >= 100
    GREATEST(0, 1.0 - 0.4 * ((p_composite - p_ceiling) / (100 - p_ceiling))^2)   otherwise

Range: [0.6, 1.0] under normal calibration (composite capped at 100 per
hiregauge_lss_delta_v2). Multiplier applied to role_fit base score alongside
the below-floor multiplier from hiregauge_lss_penalty_v2 — the two half-curves
compose to form the 2d asymmetric fit surface.

QUADRATIC COEFFICIENT: 0.4
Research grounding for coefficient selection:
- Wilk & Sackett 1996 (Personnel Psychology 49, 937-967) — ability-complexity
  misfit drives voluntary movement; underfit effect approximately 2.5x
  overfit effect magnitude. Ratio governs relative curve intensity between
  the two halves of the 2d surface.
- Floor helper max penalty (composite=0, floor=100) yields multiplier ~0.05
  (95% reduction). Ceiling helper max penalty (composite=100, ceiling below
  100) yields multiplier 0.6 (40% reduction). Ratio 0.95 / 0.40 = 2.375x,
  matching Wilk & Sackett empirical asymmetry within calibration precision.
- Coefficient 0.4 is the empirically-defensible value that produces this
  asymmetric magnitude.

CURVE SHAPE grounding (quadratic, not exponential):
- Ganzach 1998 (JAP 83, 526-539) — intelligence-satisfaction moderation by
  job complexity: high-ability workers in low-complexity roles experience
  gradually accumulating dissatisfaction, not sharp near-boundary cliff.
  Quadratic shape captures gradual accumulation better than exponential.
- Erdogan, Bauer, Peiro & Truxillo 2011 (Industrial and Organizational
  Psychology 4, 215-232) — overqualification is a construct with
  moderator-dependent outcomes (empowerment, autonomy). Effect is gradual
  and reversible, not steep and disqualifying.
- Maltarich, Nyberg & Reilly 2010 (JAP 95, 1058-1070) — cognitive ability
  x voluntary turnover overall r=-0.05 (small negative). Superstar effect
  at extreme top of demanding jobs traces to external-option pull, not
  internal-role misfit push. Justifies BOUNDED penalty (max 40% reduction),
  not open-ended.
- Brown, Wai & Chabris 2021 (Perspectives on Psychological Science 16,
  1337-1359) — acknowledged counterpoint arguing against general upper
  threshold for life outcomes. Scope distinction preserved: this ceiling
  models role-specific fit within a specific comp structure, not "too smart
  in general is bad."

MECHANISM DISTINCTION vs below-floor helper:
- Below-floor (2c/2d floor half): capability mismatch. Person cannot execute
  the cognitive demands of the role. Effect compounds. Exponential shape
  with steep near-floor gradient.
- Above-ceiling (2d ceiling half): motivation and retention mismatch. Person
  can execute but is underemployed. Effect gradual. Quadratic shape with
  bounded maximum.

Recalibration rule (per open_question "Recalibrate v3.5 competency weights
after N>=15 real hires"):
- Coefficient should be tuned empirically only when >=15 real hires have
  on-job outcome data.
- Do not tune based on candidate scores from the pre-outcome cohort.
*/
DECLARE
  c CONSTANT numeric := 0.4;
BEGIN
  IF p_composite IS NULL OR p_ceiling IS NULL THEN
    RETURN 1.0;
  ELSIF p_composite <= p_ceiling THEN
    RETURN 1.0;
  ELSIF p_ceiling >= 100 THEN
    RETURN 1.0;
  ELSE
    RETURN GREATEST(
      0.0,
      1.0 - c * POWER((p_composite - p_ceiling) / (100.0 - p_ceiling), 2)
    );
  END IF;
END;
$function$;

COMMENT ON FUNCTION public.hiregauge_lss_ceiling_penalty_v2(numeric, numeric) IS
'Above-ceiling quadratic penalty multiplier for LSS 2d role-fit curve. '
'Pair with hiregauge_lss_penalty_v2 (below-floor). Coefficient 0.4 locked '
'2026-08-01 at Step 5 kickoff per Wilk & Sackett 1996 asymmetric magnitude, '
'Ganzach 1998 / Erdogan 2011 gradual-effect shape.';
