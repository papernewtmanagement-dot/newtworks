-- Docstring-only correction, no logic change. The 20260813215248 docstring cited
-- "Ganzach 1998 JAP 83:526-539"; the paper is Ganzach, Y. (1998), Intelligence and job
-- satisfaction, Academy of Management Journal 41(5):526-539 (verified via web 2026-08-13
-- against the author's publication list and multiple citing journals). Per the standing
-- citation-quality directive, verified citations only in shipped function docstrings.
-- Function body re-shipped byte-identical except the corrected citation line:
CREATE OR REPLACE FUNCTION public._newtworks_role_fit_gated_core(p_candidate hiring_candidates, p_role_category text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
/*
Below-floor penalty (hiregauge_lss_penalty_v2, unchanged) still applies to
all roles -- ability below the role's cognitive floor is a genuine
capability mismatch (Coward & Sackett 1990 JAP 75:297-300; Zhou, Kuncel &
Sackett 2024 J Intelligence 12(4):37).

ABOVE-CEILING: as of 2026-08-13, the prior all-roles quadratic performance
penalty (hiregauge_lss_ceiling_penalty_v2, floor 0.6 / max 40% reduction,
dropped this migration) is replaced by a scoped, smaller retention-utility
discount:
  - Applies ONLY to role_category IN ('retention_reception',
    'retention_support') -- the two lowest-complexity seats in the role
    taxonomy. All other roles: ceiling multiplier forced to 1.0, no
    performance-side penalty at all.
  - Linear ramp from ideal_max to 100, floor 0.85 (max 15% reduction).
  - ALL roles (not just the two scoped ones): gma_percentile > ideal_max
    sets churn_risk = true (OR-merged with the existing reasoning-gate
    churn source) and appends 'gma_above_band' to gates_fired,
    informational only -- no score or verdict-cap effect from this flag
    alone.

Why: the prior helper's own citation stack -- Maltarich, Nyberg & Reilly
2010 JAP 95:1058-1070; Erdogan, Bauer, Peiro & Truxillo 2011 Ind-Org Psych
4:215-232; Wilk & Sackett 1996 Pers Psych 49:937-967; Ganzach 1998 Academy
of Management Journal 41:526-539 -- supports a modest RETENTION/attitude
risk in low-complexity roles from overqualification, not a general
performance decrement applied across all 7 roles. Brown, Wai & Chabris
2021 Perspectives on Psych Sci 16:1337-1359 (that helper's own newest
citation) finds ability-outcome relations monotonic-positive with no
high-end downturn -- directly contradicting a universal performance
penalty. Coward & Sackett 1990 and Arneson, Sackett & Beatty 2011 Psych
Sci 22:1000-1006 (linear ability-performance, no high-end drop) are the
reason the performance-side penalty and all-roles scope were removed
rather than kept and narrowed. Aspirant (agent-aspirant,
professional-managerial complexity) was the worst-fit case for the old
universal penalty: in complex work, LOW ability predicts voluntary
turnover, not high (Maltarich et al. 2010's own finding is specific to
low-complexity jobs).

Replaces predecessor _newtworks_role_fit_gated_core shipped
2026-08-07 under model_tag role_fit_v5_0_facet_direct_2026_08_06.
*/
DECLARE
  v_fit jsonb;
  v_integrity_gate jsonb;
  v_reasoning_gate jsonb;
  v_gates_fired text[] := ARRAY[]::text[];
  v_verdict_cap text := NULL;
  v_hard_decline boolean := false;
  v_gma_pct numeric;
  v_ideal_min numeric;
  v_ideal_max numeric;
  v_floor_mult numeric := 1.0;
  v_ceiling_mult numeric := 1.0;
  v_mult numeric := 1.0;
  v_churn_risk boolean := false;
BEGIN
  v_fit := public._newtworks_role_fit_core(p_candidate, p_role_category);

  IF v_fit ? 'error' THEN
    RETURN v_fit;
  END IF;

  v_gma_pct := (v_fit -> 'inputs' -> 'gma' ->> 'value')::numeric;

  IF v_gma_pct IS NOT NULL THEN
    SELECT intelligence_ideal_min, intelligence_ideal_max INTO v_ideal_min, v_ideal_max
      FROM public.hiregauge_role_ideal_ranges
      WHERE agency_id = p_candidate.agency_id AND role_category = p_role_category;

    IF v_ideal_min IS NOT NULL THEN
      v_floor_mult := public.hiregauge_lss_penalty_v2(v_gma_pct, v_ideal_min);
    END IF;

    IF v_ideal_max IS NOT NULL THEN
      IF p_role_category IN ('retention_reception','retention_support') AND v_gma_pct > v_ideal_max THEN
        v_ceiling_mult := GREATEST(0.85,
          1 - 0.15 * (v_gma_pct - v_ideal_max) / NULLIF(100 - v_ideal_max, 0));
      ELSE
        v_ceiling_mult := 1.0;
      END IF;

      IF v_gma_pct > v_ideal_max THEN
        v_churn_risk := true;
        v_gates_fired := array_append(v_gates_fired, 'gma_above_band');
      END IF;
    END IF;

    v_mult := v_floor_mult * v_ceiling_mult;

    v_fit := jsonb_set(v_fit, '{fit_score}',
      to_jsonb(CASE WHEN (v_fit->>'fit_score') IS NULL THEN NULL
                    ELSE ROUND(((v_fit->>'fit_score')::numeric) * v_mult, 1) END));

    IF v_mult < 1.0 THEN
      v_gates_fired := array_append(v_gates_fired, 'gma_band');
    END IF;
  END IF;

  v_integrity_gate := public._newtworks_integrity_decline_gate(p_candidate);
  IF (v_integrity_gate->>'live_soft_flag')::boolean THEN
    v_gates_fired := array_append(v_gates_fired, 'integrity_flag');
    v_verdict_cap := 'consider';
  END IF;

  v_reasoning_gate := public._newtworks_reasoning_gate(p_candidate, p_role_category);
  IF (v_reasoning_gate->>'fired')::boolean THEN
    v_gates_fired := array_append(v_gates_fired, 'reasoning_floor');
    v_verdict_cap := 'consider';
  END IF;

  v_churn_risk := v_churn_risk OR COALESCE((v_reasoning_gate->>'churn_risk_fired')::boolean, false);

  RETURN v_fit || jsonb_build_object(
    'gates_fired', to_jsonb(v_gates_fired),
    'verdict_cap', CASE WHEN v_hard_decline THEN 'decline' ELSE v_verdict_cap END,
    'hard_decline', v_hard_decline,
    'churn_risk', v_churn_risk,
    'gate_detail', jsonb_build_object(
      'gma_band', jsonb_build_object(
        'gma_percentile', v_gma_pct, 'ideal_min', v_ideal_min, 'ideal_max', v_ideal_max,
        'floor_multiplier', v_floor_mult, 'ceiling_multiplier', v_ceiling_mult, 'combined_multiplier', v_mult),
      'integrity_decline', v_integrity_gate,
      'reasoning', v_reasoning_gate
    )
  );
END;
$function$;
