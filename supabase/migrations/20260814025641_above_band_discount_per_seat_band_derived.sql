-- Per-seat above-band retention discount, sized FROM each seat's own band (Peter
-- decision 2026-08-14): every seat except aspirant carries the discount, and its
-- maximum is derived from the seat's band width above the ceiling rather than a flat
-- 15%. Rationale: intelligence_ideal_max already encodes seat complexity -- the lower
-- the ceiling, the lower-complexity the seat, and the ability->voluntary-turnover
-- effect is strongest in low-complexity work and reverses in complex work (Maltarich,
-- Nyberg & Reilly 2010 JAP 95:1058-1070; Erdogan et al. 2011 overqualification).
-- Seed formula: round(0.0075 * (100 - intelligence_ideal_max), 2); aspirant pinned to
-- 0 (professional-managerial complexity -- high ability is the point of the seat, and
-- in complex work LOW ability predicts leaving). Yields at current bands:
--   retention_support (max 80)   -> 0.15  (unchanged from the hard-coded value)
--   retention_reception (max 85) -> 0.11  (down from hard-coded 0.15)
--   sales_inbound (max 90)       -> 0.08  (new)
--   sales_outbound (max 90)      -> 0.08  (new)
--   retention_escalation (max 90)-> 0.08  (new)
--   sales_in_book (max 92)       -> 0.06  (new)
--   aspirant (max 93)            -> 0     (exempt by decision)
-- The gma_above_band churn flag stays informational on ALL seats including aspirant.
-- If a band edge is later re-tuned, re-run the seed formula or set the column by hand.

ALTER TABLE public.hiregauge_role_ideal_ranges
  ADD COLUMN IF NOT EXISTS above_band_max_discount numeric NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.hiregauge_role_ideal_ranges.above_band_max_discount IS
  'Maximum retention-utility discount (0-1 fraction) applied to role fit when the candidate''s GMA percentile exceeds intelligence_ideal_max. Linear ramp from ideal_max to 100, floor 1 - this value. 0 disables. Seeded 2026-08-14 as round(0.0075*(100-intelligence_ideal_max),2) with aspirant pinned 0; basis Maltarich 2010 complexity gradient.';

UPDATE public.hiregauge_role_ideal_ranges
SET above_band_max_discount = CASE
      WHEN role_category = 'aspirant' THEN 0
      ELSE round(0.0075 * (100 - intelligence_ideal_max), 2)
    END
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND intelligence_ideal_max IS NOT NULL;

-- Gated core: ceiling discount now read per seat from the column above; the two
-- hard-coded role names and the flat 0.15 are gone. Everything else unchanged.
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

    IF v_ideal_min IS NOT NULL THEN
      v_floor_mult := public.hiregauge_lss_penalty_v2(v_gma_pct, v_ideal_min);
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
