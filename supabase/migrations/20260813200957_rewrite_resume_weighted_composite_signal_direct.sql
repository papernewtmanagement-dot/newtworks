-- Resume scoring revamp: resume_weighted_composite rewritten signal-direct
-- Approved spec: session_note "2026-08-12 — Resume scoring revamp: approved spec
-- (signal-level weights + LE anchors + autonomy imputation)"
--
-- Constructs (Capability/Character/Commitment) remain DISPLAY groupings only
-- (simple means, computed elsewhere for UI). This composite is signal-direct:
-- a weighted sum over hiregauge_resume_signal_weights, same pattern as
-- role_fit_v5_0_facet_direct. Any weight>0 signal missing/null -> NULL
-- (fail loudly; no renormalizing, no per-candidate reweight).
--
-- Citations (verified 2026-08-12):
--   McDaniel, Schmidt & Hunter 1988, Personnel Psychology 41 -- T&E
--     behavioral-consistency r=.45 vs point method r=.11.
--   Van Iddekinge, Arnold, Frieder & Roth 2019, Personnel Psychology 72 --
--     prehire experience r=.06 performance, r=.00 turnover.
--   Sackett, Zhang, Berry & Lievens 2022, J Applied Psych 107 -- structured
--     interviews r=.42, empirically keyed biodata r=.38, GMA r=.31,
--     conscientiousness r=.19.
--   Vinchur, Schippmann, Switzer & Roth 1998, J Applied Psych 83 -- sales
--     biodata r=.52 (ratings criterion); achievement r=.41 (objective);
--     GMA r=.04 (objective).
--   Cole, Feild, Giles & Harris 2009, J Business & Psychology 24 --
--     resume-based personality inference unreliable/invalid.
--   Rosenbaum 1979, Admin Science Quarterly 24 -- early promotion shapes
--     later advancement (mixed replication noted).
--   Mael 1991, Personnel Psychology 44 -- biodata equal-access item principle.

CREATE OR REPLACE FUNCTION public.resume_weighted_composite(p_resume_analysis jsonb)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  WITH w AS (
    SELECT signal_key, weight
    FROM public.hiregauge_resume_signal_weights
    WHERE weight > 0
  ),
  scored AS (
    SELECT
      w.signal_key,
      w.weight,
      (p_resume_analysis->'signals'->w.signal_key->>'score')::numeric AS score
    FROM w
  )
  SELECT
    CASE
      WHEN bool_and(score IS NOT NULL) THEN round(sum(weight * score), 2)
      ELSE NULL
    END
  FROM scored;
$function$;
