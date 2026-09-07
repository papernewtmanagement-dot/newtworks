CREATE OR REPLACE FUNCTION public._newtworks_role_fit_gated_core(p_candidate hiring_candidates, p_role_category text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
/*
BELOW-BAND (changed 2026-09-04, role_fit_gated_v5_10): the below-floor
multiplier (hiregauge_lss_penalty_v2, exponential to a 0.5 saturation) is
REMOVED from the score and replaced by an informational flag,
'gma_below_band'. Reasons, in order of weight:
 1. The ability-performance relationship is linear across the whole range
    (Coward & Sackett 1990 JAP 75:297-300, 174 samples; Arneson, Sackett &
    Beatty 2011 Psych Sci 22:1336-1342, which tested and rejected the
    "good enough / threshold" hypothesis directly). The gma percentile
    already enters the weighted sum linearly at its role weight; a second,
    non-linear penalty on the same signal double-counts it. The penalty
    function's own docstring concedes it was "a scoring design choice for
    the near-floor decision window, not an empirical curve fit".
 2. The "floor" (hiregauge_role_ideal_ranges.intelligence_ideal_min, 25-55)
    is not an ability level. It is a PERCENTILE against a local applicant
    norm of nineteen people, so who gets halved depends on who else applied
    that month. Norm samples this small carry sampling error far larger
    than the band itself (AERA/APA/NCME Standards 2014 ch. 5; Petersen,
    Kolen & Hoover 1989 in Educational Measurement 3rd ed.).
 3. Observed effect on the first 20 forced-choice completions: the only
    three candidates under the 60 auto-decline line were exactly the three
    the multiplier halved (fit 69 -> 35 for a 7-of-16 candidate). The
    multiplier manufactured the decline cluster.
 4. Low ability is already caught twice upstream where it belongs: stint-1
    gate C (at or below the guessing mean, hard eliminator) and the
    reasoning floor (chance + 2 SD, verdict cap). A third mechanism on the
    same input is redundant.
 5. Cognitive measures carry the largest subgroup mean differences of any
    common selection tool (Roth, Bevier, Bobko, Switzer & Tyler 2001 Pers
    Psych 54:297-330), so a non-linear GMA penalty unsupported by criterion
    evidence is the least defensible element of a hiring process.
The flag keeps the signal visible for the interviewer (probe learning speed
and how they handled the reasoning items) without moving the score. Whether
gma's LINEAR weight should rise now that the multiplier is gone is a
recalibration question for N >= 25 with on-job outcome data (Sackett, Zhang,
Berry & Lievens 2022 JAP 107:2040-2068 put cognitive ability's operational
validity at ~.31, comparable to the strongest single personality facets).

ABOVE-CEILING (2026-08-14, supersedes the 2026-08-13 two-seat scope): a
per-seat retention-utility discount read from
hiregauge_role_ideal_ranges.above_band_max_discount. Linear ramp from
ideal_max to 100; floor 1 - max_discount; 0 disables the discount for that
seat. Seeded from band width (round(0.0075*(100-ideal_max),2)), aspirant
pinned 0 -- see the 20260814 above_band_discount_per_seat_band_derived
migration for the seat table and rationale. This is a RETENTION-utility
discount, not a performance penalty: ability-performance is monotonic
positive at every level (Brown, Wai & Chabris 2021 Perspectives on Psych
Sci 16:1337-1359; Arneson, Sackett & Beatty 2011 Psych Sci 22:1000-1006;
Coward & Sackett 1990), while ability above a low-complexity seat's band
predicts voluntary exit (Maltarich, Nyberg & Reilly 2010 JAP 95:1058-1070;
Erdogan, Bauer, Peiro & Truxillo 2011 Ind-Org Psych 4:215-232; Wilk &
Sackett 1996 Pers Psych 49:937-967; Ganzach 1998 Academy of Management
Journal 41:526-539). In complex work LOW ability predicts leaving, which
is why aspirant carries no discount.

ALL roles (aspirant included): gma_percentile > ideal_max sets churn_risk
= true (OR-merged with the reasoning-gate churn source) and appends
'gma_above_band' to gates_fired, informational only.

Replaces predecessor shipped 2026-08-13 (two-seat hard-coded scope), which
replaced the 2026-08-07 all-roles quadratic performance penalty under
model_tag role_fit_v5_0_facet_direct_2026_08_06.
model_tag role_fit_gated_v5_10_below_band_flag_only_2026_09_04.
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
  v_max_disc numeric := 0;
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
    SELECT intelligence_ideal_min, intelligence_ideal_max, COALESCE(above_band_max_discount, 0)
      INTO v_ideal_min, v_ideal_max, v_max_disc
      FROM public.hiregauge_role_ideal_ranges
      WHERE agency_id = p_candidate.agency_id AND role_category = p_role_category;

    -- v5_10: below-band is a FLAG, never a multiplier (see docstring).
    v_floor_mult := 1.0;
    IF v_ideal_min IS NOT NULL AND v_gma_pct < v_ideal_min THEN
      v_gates_fired := array_append(v_gates_fired, 'gma_below_band');
    END IF;

    IF v_ideal_max IS NOT NULL THEN
      IF v_max_disc > 0 AND v_gma_pct > v_ideal_max THEN
        v_ceiling_mult := GREATEST(1 - v_max_disc,
          1 - v_max_disc * (v_gma_pct - v_ideal_max) / NULLIF(100 - v_ideal_max, 0));
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
        'max_discount', v_max_disc,
        'floor_multiplier', v_floor_mult, 'ceiling_multiplier', v_ceiling_mult, 'combined_multiplier', v_mult),
      'integrity_decline', v_integrity_gate,
      'reasoning', v_reasoning_gate
    )
  );
END;
$function$;

-- scoring-formula change: manual version bump (op-rule)
UPDATE public.hiregauge_scoring_version SET version = version + 1, updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';
