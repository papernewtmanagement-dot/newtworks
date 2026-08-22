-- v3:
-- (a) accept p_months_back (default 12) so the frontend lookback selector can
--     pull 24/36 months for premium rows without a second RPC.
-- (b) return prior-year premium arrays (auto/fire/life _premium_prior_year) so
--     the frontend can render a same-month YoY dashed overlay on the chart
--     without a second call.
--
-- Gain, Life NPF, and rate arrays remain accurate only where source data
-- exists (YTD cols and comp_recap start June 2026); older months null out
-- inside the array rather than shortening it. Premium arrays populate all
-- p_months_back slots (cadence='monthly' history goes back to 2018 with
-- weekly fallback for the current month).
--
-- Drop the old 2-arg signature first — Postgres does not replace across
-- different arities (per op-rule "Function-signature changes: drop old
-- overload or all short-arg callers break").

DROP FUNCTION IF EXISTS public.get_agency_perf_monthly_series(uuid, date);

CREATE OR REPLACE FUNCTION public.get_agency_perf_monthly_series(
  p_agency_id uuid,
  p_week_ending_date date,
  p_months_back int DEFAULT 12
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_i           int;
  v_month_start date;
  v_month_end   date;
  v_labels      text[]   := ARRAY[]::text[];
  v_auto_new    numeric[] := ARRAY[]::numeric[];
  v_auto_lost   numeric[] := ARRAY[]::numeric[];
  v_auto_gain   numeric[] := ARRAY[]::numeric[];
  v_fire_new    numeric[] := ARRAY[]::numeric[];
  v_fire_lost   numeric[] := ARRAY[]::numeric[];
  v_fire_gain   numeric[] := ARRAY[]::numeric[];
  v_life_new    numeric[] := ARRAY[]::numeric[];
  v_life_lost   numeric[] := ARRAY[]::numeric[];
  v_life_gain   numeric[] := ARRAY[]::numeric[];
  v_life_npf_ct numeric[] := ARRAY[]::numeric[];
  v_life_npf_pr numeric[] := ARRAY[]::numeric[];
  v_auto_prem   numeric[] := ARRAY[]::numeric[];
  v_fire_prem   numeric[] := ARRAY[]::numeric[];
  v_life_prem   numeric[] := ARRAY[]::numeric[];
  v_auto_prem_py numeric[] := ARRAY[]::numeric[];
  v_fire_prem_py numeric[] := ARRAY[]::numeric[];
  v_life_prem_py numeric[] := ARRAY[]::numeric[];
  v_smvc_pct    numeric[] := ARRAY[]::numeric[];
  v_smvc_dol    numeric[] := ARRAY[]::numeric[];
  v_scorecard   numeric[] := ARRAY[]::numeric[];

  v_end_auto_new numeric; v_end_auto_lost numeric;
  v_end_fire_new numeric; v_end_fire_lost numeric;
  v_end_life_new numeric; v_end_life_lost numeric;
  v_end_life_ct  numeric; v_end_life_pr   numeric;

  v_prev_auto_new numeric; v_prev_auto_lost numeric;
  v_prev_fire_new numeric; v_prev_fire_lost numeric;
  v_prev_life_new numeric; v_prev_life_lost numeric;
  v_prev_life_ct  numeric; v_prev_life_pr   numeric;

  v_ap numeric; v_fp numeric; v_lp numeric;
  v_ap_py numeric; v_fp_py numeric; v_lp_py numeric;
  v_py_month_start date; v_py_month_end date;

  v_smvc_json jsonb;
  v_sc_json   jsonb;
  v_smvc_pct_val numeric;
  v_smvc_pc_prem numeric;
  v_sc_val       numeric;
BEGIN
  IF p_months_back IS NULL OR p_months_back < 1 THEN p_months_back := 12; END IF;
  IF p_months_back > 60 THEN p_months_back := 60; END IF;

  FOR v_i IN 0..(p_months_back - 1) LOOP
    v_month_start := (date_trunc('month', p_week_ending_date)::date - (p_months_back - 1 - v_i) * INTERVAL '1 month')::date;
    v_month_end   := (v_month_start + INTERVAL '1 month' - INTERVAL '1 day')::date;
    v_labels := v_labels || to_char(v_month_start, 'YYYY-MM');

    -- End-of-month YTD gain values (latest weekly on-or-before month-end with YTD populated)
    v_end_auto_new := NULL; v_end_auto_lost := NULL;
    v_end_fire_new := NULL; v_end_fire_lost := NULL;
    v_end_life_new := NULL; v_end_life_lost := NULL;
    v_end_life_ct  := NULL; v_end_life_pr   := NULL;
    SELECT auto_new_ytd, auto_lost_ytd, fire_new_ytd, fire_lost_ytd,
           life_new_ytd, life_lost_ytd, life_paid_for_count_ytd, life_paid_for_premium_ytd
    INTO   v_end_auto_new, v_end_auto_lost, v_end_fire_new, v_end_fire_lost,
           v_end_life_new, v_end_life_lost, v_end_life_ct, v_end_life_pr
    FROM   public.agency_snapshot
    WHERE  agency_id     = p_agency_id
      AND  cadence       = 'weekly'
      AND  snapshot_date <= v_month_end
      AND  auto_new_ytd IS NOT NULL
    ORDER  BY snapshot_date DESC
    LIMIT  1;

    IF EXTRACT(MONTH FROM v_month_start) = 1 THEN
      v_prev_auto_new := 0; v_prev_auto_lost := 0;
      v_prev_fire_new := 0; v_prev_fire_lost := 0;
      v_prev_life_new := 0; v_prev_life_lost := 0;
      v_prev_life_ct  := 0; v_prev_life_pr   := 0;
    ELSE
      v_prev_auto_new := NULL; v_prev_auto_lost := NULL;
      v_prev_fire_new := NULL; v_prev_fire_lost := NULL;
      v_prev_life_new := NULL; v_prev_life_lost := NULL;
      v_prev_life_ct  := NULL; v_prev_life_pr   := NULL;
      SELECT auto_new_ytd, auto_lost_ytd, fire_new_ytd, fire_lost_ytd,
             life_new_ytd, life_lost_ytd, life_paid_for_count_ytd, life_paid_for_premium_ytd
      INTO   v_prev_auto_new, v_prev_auto_lost, v_prev_fire_new, v_prev_fire_lost,
             v_prev_life_new, v_prev_life_lost, v_prev_life_ct, v_prev_life_pr
      FROM   public.agency_snapshot
      WHERE  agency_id     = p_agency_id
        AND  cadence       = 'weekly'
        AND  snapshot_date <  v_month_start
        AND  auto_new_ytd IS NOT NULL
      ORDER  BY snapshot_date DESC
      LIMIT  1;
    END IF;

    v_auto_new  := v_auto_new  || CASE WHEN v_end_auto_new IS NULL OR v_prev_auto_new IS NULL THEN NULL::numeric ELSE v_end_auto_new  - v_prev_auto_new  END;
    v_auto_lost := v_auto_lost || CASE WHEN v_end_auto_lost IS NULL OR v_prev_auto_lost IS NULL THEN NULL::numeric ELSE v_end_auto_lost - v_prev_auto_lost END;
    v_auto_gain := v_auto_gain || CASE WHEN v_end_auto_new IS NULL OR v_prev_auto_new IS NULL OR v_end_auto_lost IS NULL OR v_prev_auto_lost IS NULL THEN NULL::numeric
                                       ELSE (v_end_auto_new - v_prev_auto_new) - (v_end_auto_lost - v_prev_auto_lost) END;

    v_fire_new  := v_fire_new  || CASE WHEN v_end_fire_new IS NULL OR v_prev_fire_new IS NULL THEN NULL::numeric ELSE v_end_fire_new  - v_prev_fire_new  END;
    v_fire_lost := v_fire_lost || CASE WHEN v_end_fire_lost IS NULL OR v_prev_fire_lost IS NULL THEN NULL::numeric ELSE v_end_fire_lost - v_prev_fire_lost END;
    v_fire_gain := v_fire_gain || CASE WHEN v_end_fire_new IS NULL OR v_prev_fire_new IS NULL OR v_end_fire_lost IS NULL OR v_prev_fire_lost IS NULL THEN NULL::numeric
                                       ELSE (v_end_fire_new - v_prev_fire_new) - (v_end_fire_lost - v_prev_fire_lost) END;

    v_life_new  := v_life_new  || CASE WHEN v_end_life_new IS NULL OR v_prev_life_new IS NULL THEN NULL::numeric ELSE v_end_life_new  - v_prev_life_new  END;
    v_life_lost := v_life_lost || CASE WHEN v_end_life_lost IS NULL OR v_prev_life_lost IS NULL THEN NULL::numeric ELSE v_end_life_lost - v_prev_life_lost END;
    v_life_gain := v_life_gain || CASE WHEN v_end_life_new IS NULL OR v_prev_life_new IS NULL OR v_end_life_lost IS NULL OR v_prev_life_lost IS NULL THEN NULL::numeric
                                       ELSE (v_end_life_new - v_prev_life_new) - (v_end_life_lost - v_prev_life_lost) END;

    v_life_npf_ct := v_life_npf_ct || CASE WHEN v_end_life_ct IS NULL OR v_prev_life_ct IS NULL THEN NULL::numeric ELSE v_end_life_ct - v_prev_life_ct END;
    v_life_npf_pr := v_life_npf_pr || CASE WHEN v_end_life_pr IS NULL OR v_prev_life_pr IS NULL THEN NULL::numeric ELSE v_end_life_pr - v_prev_life_pr END;

    -- Premium book: prefer next-month-1st monthly snapshot (= end of this month),
    -- fallback this-month-1st monthly, fallback latest weekly on-or-before month-end.
    v_ap := NULL; v_fp := NULL; v_lp := NULL;
    SELECT auto_premium, fire_premium, life_premium
    INTO   v_ap, v_fp, v_lp
    FROM   public.agency_snapshot
    WHERE  agency_id = p_agency_id
      AND  cadence = 'monthly'
      AND  snapshot_date = (v_month_end + 1)
    LIMIT  1;
    IF v_ap IS NULL AND v_fp IS NULL AND v_lp IS NULL THEN
      SELECT auto_premium, fire_premium, life_premium
      INTO   v_ap, v_fp, v_lp
      FROM   public.agency_snapshot
      WHERE  agency_id = p_agency_id
        AND  cadence = 'monthly'
        AND  snapshot_date = v_month_start
      LIMIT  1;
    END IF;
    IF v_ap IS NULL AND v_fp IS NULL AND v_lp IS NULL THEN
      SELECT auto_premium, fire_premium, life_premium
      INTO   v_ap, v_fp, v_lp
      FROM   public.agency_snapshot
      WHERE  agency_id = p_agency_id
        AND  cadence = 'weekly'
        AND  snapshot_date <= v_month_end
        AND  snapshot_date >= v_month_start
      ORDER  BY snapshot_date DESC
      LIMIT  1;
    END IF;
    v_auto_prem := v_auto_prem || v_ap;
    v_fire_prem := v_fire_prem || v_fp;
    v_life_prem := v_life_prem || v_lp;

    -- Prior-year same-month premium for YoY dashed overlay
    v_py_month_start := (v_month_start - INTERVAL '1 year')::date;
    v_py_month_end   := (v_py_month_start + INTERVAL '1 month' - INTERVAL '1 day')::date;
    v_ap_py := NULL; v_fp_py := NULL; v_lp_py := NULL;
    SELECT auto_premium, fire_premium, life_premium
    INTO   v_ap_py, v_fp_py, v_lp_py
    FROM   public.agency_snapshot
    WHERE  agency_id = p_agency_id
      AND  cadence = 'monthly'
      AND  snapshot_date = (v_py_month_end + 1)
    LIMIT  1;
    IF v_ap_py IS NULL AND v_fp_py IS NULL AND v_lp_py IS NULL THEN
      SELECT auto_premium, fire_premium, life_premium
      INTO   v_ap_py, v_fp_py, v_lp_py
      FROM   public.agency_snapshot
      WHERE  agency_id = p_agency_id
        AND  cadence = 'monthly'
        AND  snapshot_date = v_py_month_start
      LIMIT  1;
    END IF;
    v_auto_prem_py := v_auto_prem_py || v_ap_py;
    v_fire_prem_py := v_fire_prem_py || v_fp_py;
    v_life_prem_py := v_life_prem_py || v_lp_py;

    v_smvc_json    := public.compute_agency_on_time_smvc(p_agency_id, v_month_end);
    v_smvc_pct_val := NULLIF(v_smvc_json->>'on_time_smvc_pct', '')::numeric;
    v_smvc_pc_prem := NULLIF(v_smvc_json->>'pc_book_premium', '')::numeric;
    v_sc_json      := public.compute_scorecard_bonus(p_agency_id, v_month_end);
    v_sc_val       := NULLIF(v_sc_json->>'bonus_projected', '')::numeric;

    v_smvc_pct  := v_smvc_pct  || v_smvc_pct_val;
    v_smvc_dol  := v_smvc_dol  || CASE WHEN v_smvc_pct_val IS NULL OR v_smvc_pc_prem IS NULL OR v_smvc_pc_prem = 0 THEN NULL::numeric ELSE v_smvc_pct_val * v_smvc_pc_prem END;
    v_scorecard := v_scorecard || v_sc_val;
  END LOOP;

  RETURN jsonb_build_object(
    'months',                to_jsonb(v_labels),
    'months_back',           p_months_back,
    'auto_new',              to_jsonb(v_auto_new),
    'auto_lost',             to_jsonb(v_auto_lost),
    'auto_gain',             to_jsonb(v_auto_gain),
    'fire_new',              to_jsonb(v_fire_new),
    'fire_lost',             to_jsonb(v_fire_lost),
    'fire_gain',             to_jsonb(v_fire_gain),
    'life_new',              to_jsonb(v_life_new),
    'life_lost',             to_jsonb(v_life_lost),
    'life_gain',             to_jsonb(v_life_gain),
    'life_npf_count',        to_jsonb(v_life_npf_ct),
    'life_npf_premium',      to_jsonb(v_life_npf_pr),
    'auto_premium',          to_jsonb(v_auto_prem),
    'fire_premium',          to_jsonb(v_fire_prem),
    'life_premium',          to_jsonb(v_life_prem),
    'auto_premium_prior_year', to_jsonb(v_auto_prem_py),
    'fire_premium_prior_year', to_jsonb(v_fire_prem_py),
    'life_premium_prior_year', to_jsonb(v_life_prem_py),
    'smvc_pct',              to_jsonb(v_smvc_pct),
    'smvc_dollars',          to_jsonb(v_smvc_dol),
    'scorecard',             to_jsonb(v_scorecard),
    'computed_at',           now()
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_agency_perf_monthly_series(uuid, date, int) TO anon, authenticated, service_role;
