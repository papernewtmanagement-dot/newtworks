-- v2: add weekly-snapshot fallback for premium rows in the current month
-- (agency_snapshot cadence='monthly' rows don't exist yet for the current
-- month until SF publishes the next monthly analytics row on ~1st of next
-- month). This keeps the Current-month column populated with the freshest
-- weekly book values instead of showing null.

CREATE OR REPLACE FUNCTION public.get_agency_perf_monthly_series(
  p_agency_id uuid,
  p_week_ending_date date
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

  v_smvc_json jsonb;
  v_sc_json   jsonb;
  v_smvc_pct_val numeric;
  v_smvc_pc_prem numeric;
  v_sc_val       numeric;
BEGIN
  FOR v_i IN 0..11 LOOP
    v_month_start := (date_trunc('month', p_week_ending_date)::date - (11 - v_i) * INTERVAL '1 month')::date;
    v_month_end   := (v_month_start + INTERVAL '1 month' - INTERVAL '1 day')::date;
    v_labels := v_labels || to_char(v_month_start, 'YYYY-MM');

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
    -- fallback this-month-1st monthly, fallback latest weekly on-or-before month-end
    -- (used for the current month where SF has not yet published a monthly row).
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
    'months',           to_jsonb(v_labels),
    'auto_new',         to_jsonb(v_auto_new),
    'auto_lost',        to_jsonb(v_auto_lost),
    'auto_gain',        to_jsonb(v_auto_gain),
    'fire_new',         to_jsonb(v_fire_new),
    'fire_lost',        to_jsonb(v_fire_lost),
    'fire_gain',        to_jsonb(v_fire_gain),
    'life_new',         to_jsonb(v_life_new),
    'life_lost',        to_jsonb(v_life_lost),
    'life_gain',        to_jsonb(v_life_gain),
    'life_npf_count',   to_jsonb(v_life_npf_ct),
    'life_npf_premium', to_jsonb(v_life_npf_pr),
    'auto_premium',     to_jsonb(v_auto_prem),
    'fire_premium',     to_jsonb(v_fire_prem),
    'life_premium',     to_jsonb(v_life_prem),
    'smvc_pct',         to_jsonb(v_smvc_pct),
    'smvc_dollars',     to_jsonb(v_smvc_dol),
    'scorecard',        to_jsonb(v_scorecard),
    'computed_at',      now()
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_agency_perf_monthly_series(uuid, date) TO anon, authenticated, service_role;
