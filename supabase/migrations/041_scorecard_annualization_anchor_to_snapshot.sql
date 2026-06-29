-- Migration 041: Scorecard annualization anchored to data freshness.
--
-- Bug: compute_scorecard_bonus pace_factor was using p_as_of_date for annualization
-- (typically CURRENT_DATE) even when YTD inputs came from a stale agency_snapshot.
-- Stretching N-day-old data across M>N calendar days understated pace. Material
-- impact via FS Eligibility multiplier compounding into eligible commissions.
--
-- Fix: anchor days_elapsed to LEAST(p_as_of_date, v_snap.snapshot_date) when a
-- snapshot is available. Falls back to p_as_of_date when there's no snapshot
-- (manual-overrides-only mode). When overrides exist for the as-of week, treat
-- the week date as the data anchor (overrides reflect that week).
--
-- New field in returned JSONB: effective_as_of_date.

CREATE OR REPLACE FUNCTION public.compute_scorecard_bonus(p_agency_id uuid, p_as_of_date date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_year         int := EXTRACT(YEAR FROM p_as_of_date)::int;
  v_snap         record;
  v_report       record;  -- weekly_cpr_reports manual overrides for the as-of week
  v_effective_as_of date;
  v_days_elapsed int;
  v_pace_factor  numeric;

  v_career_tier  text;
  v_hc_tier_points int;
  v_last_year_bonus numeric;

  v_auto_prod_min numeric; v_auto_prod_max numeric;
  v_auto_gain_min numeric; v_auto_gain_max numeric;
  v_fire_prod_min numeric; v_fire_prod_max numeric;
  v_fire_gain_min numeric; v_fire_gain_max numeric;
  v_fs_credits_min numeric; v_fs_credits_max numeric;
  v_hc_npf_gate numeric; v_hc_credits_gate numeric;

  v_auto_prod_ytd numeric; v_auto_gain_ytd numeric;
  v_fire_prod_ytd numeric; v_fire_gain_ytd numeric;
  v_life_npf_ytd numeric; v_life_credits_ytd numeric;
  v_ips_activity_ytd numeric;
  v_fs_credits_ytd numeric;

  v_auto_prod_proj numeric; v_auto_gain_proj numeric;
  v_fire_prod_proj numeric; v_fire_gain_proj numeric;
  v_life_npf_proj numeric; v_life_credits_proj numeric;
  v_fs_credits_proj numeric;

  v_auto_prod_pts numeric; v_auto_gain_pts numeric; v_auto_best_pts numeric;
  v_fire_prod_pts numeric; v_fire_gain_pts numeric; v_fire_best_pts numeric;
  v_fs_pts numeric;
  v_hc_pts int;
  v_hc_qualified boolean;
  v_total_pts numeric;

  v_auto_gain_mod numeric;
  v_fire_gain_mod numeric;
  v_fs_eligibility_mult numeric;

  v_auto_nc_ytd numeric;
  v_fire_nc_ytd numeric;
  v_life_nc_ytd numeric;
  v_health_nc_ytd numeric;

  v_auto_eligible numeric;
  v_fire_eligible numeric;
  v_life_eligible numeric;
  v_health_eligible numeric;
  v_total_eligible numeric;
  v_total_eligible_proj numeric;

  v_bonus_rate numeric;
  v_bonus_ytd numeric;
  v_bonus_projected numeric;

  v_has_overrides boolean := false;
BEGIN
  SELECT honor_club_career_tier, scorecard_bonus_paid_prior_year
  INTO v_career_tier, v_last_year_bonus
  FROM public.agency WHERE id = p_agency_id;

  v_hc_tier_points := CASE v_career_tier
    WHEN 'honor' THEN 85
    WHEN 'bronze' THEN 95
    WHEN 'silver' THEN 105
    WHEN 'gold' THEN 115
    WHEN 'crystal' THEN 125
    ELSE 0
  END;

  SELECT min_target, max_target INTO v_auto_prod_min, v_auto_prod_max
  FROM public.sf_program_targets
  WHERE agency_id=p_agency_id AND program='scorecard'
    AND bucket_name='auto_pif_production' AND program_year=v_year;

  SELECT min_target, max_target INTO v_auto_gain_min, v_auto_gain_max
  FROM public.sf_program_targets
  WHERE agency_id=p_agency_id AND program='scorecard'
    AND bucket_name='auto_pif_gain' AND program_year=v_year;

  SELECT min_target, max_target INTO v_fire_prod_min, v_fire_prod_max
  FROM public.sf_program_targets
  WHERE agency_id=p_agency_id AND program='scorecard'
    AND bucket_name='fire_pif_production' AND program_year=v_year;

  SELECT min_target, max_target INTO v_fire_gain_min, v_fire_gain_max
  FROM public.sf_program_targets
  WHERE agency_id=p_agency_id AND program='scorecard'
    AND bucket_name='fire_pif_gain' AND program_year=v_year;

  SELECT min_target, max_target INTO v_fs_credits_min, v_fs_credits_max
  FROM public.sf_program_targets
  WHERE agency_id=p_agency_id AND program='scorecard'
    AND bucket_name='fs_credits' AND program_year=v_year;

  SELECT min_target INTO v_hc_npf_gate
  FROM public.sf_program_targets
  WHERE agency_id=p_agency_id AND program='honor_club'
    AND bucket_name='honor_club_life_policies_gate' AND program_year=v_year;

  SELECT min_target INTO v_hc_credits_gate
  FROM public.sf_program_targets
  WHERE agency_id=p_agency_id AND program='honor_club'
    AND bucket_name='honor_club_life_credits_gate' AND program_year=v_year;

  SELECT * INTO v_snap
  FROM public.agency_snapshot
  WHERE agency_id = p_agency_id
    AND snapshot_date <= p_as_of_date
    AND auto_new_ytd IS NOT NULL
  ORDER BY snapshot_date DESC
  LIMIT 1;

  SELECT
    auto_new_ytd_manual, auto_lost_ytd_manual,
    fire_new_ytd_manual, fire_lost_ytd_manual,
    life_paid_for_count_ytd_manual, life_paid_for_premium_ytd_manual
  INTO v_report
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id
    AND week_ending_date = p_as_of_date;

  v_has_overrides := (v_report.auto_new_ytd_manual IS NOT NULL
                   OR v_report.auto_lost_ytd_manual IS NOT NULL
                   OR v_report.fire_new_ytd_manual IS NOT NULL
                   OR v_report.fire_lost_ytd_manual IS NOT NULL
                   OR v_report.life_paid_for_count_ytd_manual IS NOT NULL
                   OR v_report.life_paid_for_premium_ytd_manual IS NOT NULL);

  IF v_snap.snapshot_date IS NULL AND NOT v_has_overrides THEN
    RETURN jsonb_build_object(
      'error', 'No agency_snapshot row with YTD data and no manual overrides for the target week',
      'as_of_date', p_as_of_date,
      'last_year_bonus', v_last_year_bonus
    );
  END IF;

  v_effective_as_of := COALESCE(
    CASE WHEN v_has_overrides THEN p_as_of_date ELSE NULL END,
    v_snap.snapshot_date,
    p_as_of_date
  );
  v_effective_as_of := LEAST(p_as_of_date, v_effective_as_of);

  v_days_elapsed := LEAST(365, EXTRACT(DOY FROM v_effective_as_of)::int);
  v_pace_factor := 365.0 / GREATEST(1, v_days_elapsed);

  v_auto_prod_ytd     := COALESCE(v_report.auto_new_ytd_manual,            v_snap.auto_new_ytd,                0);
  v_auto_gain_ytd     := v_auto_prod_ytd
                       - COALESCE(v_report.auto_lost_ytd_manual,           v_snap.auto_lost_ytd,               0);
  v_fire_prod_ytd     := COALESCE(v_report.fire_new_ytd_manual,            v_snap.fire_new_ytd,                0);
  v_fire_gain_ytd     := v_fire_prod_ytd
                       - COALESCE(v_report.fire_lost_ytd_manual,           v_snap.fire_lost_ytd,               0);
  v_life_npf_ytd      := COALESCE(v_report.life_paid_for_count_ytd_manual, v_snap.life_paid_for_count_ytd,     0);
  v_life_credits_ytd  := COALESCE(v_report.life_paid_for_premium_ytd_manual, v_snap.life_paid_for_premium_ytd, 0);
  v_ips_activity_ytd  := COALESCE(v_snap.ips_new_money_ytd, 0);
  v_fs_credits_ytd    := v_life_credits_ytd + v_ips_activity_ytd;

  v_auto_prod_proj    := v_auto_prod_ytd * v_pace_factor;
  v_auto_gain_proj    := v_auto_gain_ytd * v_pace_factor;
  v_fire_prod_proj    := v_fire_prod_ytd * v_pace_factor;
  v_fire_gain_proj    := v_fire_gain_ytd * v_pace_factor;
  v_life_npf_proj     := v_life_npf_ytd * v_pace_factor;
  v_life_credits_proj := v_life_credits_ytd * v_pace_factor;
  v_fs_credits_proj   := v_fs_credits_ytd * v_pace_factor;

  v_auto_prod_pts := GREATEST(0, LEAST(125,
    CASE WHEN v_auto_prod_max > v_auto_prod_min
         THEN ((v_auto_prod_proj - v_auto_prod_min) / (v_auto_prod_max - v_auto_prod_min)) * 125
         ELSE 0 END));
  v_auto_gain_pts := GREATEST(0, LEAST(200,
    CASE WHEN v_auto_gain_max > v_auto_gain_min
         THEN ((v_auto_gain_proj - v_auto_gain_min) / (v_auto_gain_max - v_auto_gain_min)) * 200
         ELSE 0 END));
  v_auto_best_pts := GREATEST(v_auto_prod_pts, v_auto_gain_pts);

  v_fire_prod_pts := GREATEST(0, LEAST(100,
    CASE WHEN v_fire_prod_max > v_fire_prod_min
         THEN ((v_fire_prod_proj - v_fire_prod_min) / (v_fire_prod_max - v_fire_prod_min)) * 100
         ELSE 0 END));
  v_fire_gain_pts := GREATEST(0, LEAST(100,
    CASE WHEN v_fire_gain_max > v_fire_gain_min
         THEN ((v_fire_gain_proj - v_fire_gain_min) / (v_fire_gain_max - v_fire_gain_min)) * 100
         ELSE 0 END));
  v_fire_best_pts := GREATEST(v_fire_prod_pts, v_fire_gain_pts);

  v_fs_pts := GREATEST(0, LEAST(225,
    CASE WHEN v_fs_credits_max > v_fs_credits_min
         THEN ((v_fs_credits_proj - v_fs_credits_min) / (v_fs_credits_max - v_fs_credits_min)) * 225
         ELSE 0 END));

  v_hc_qualified := v_life_npf_proj >= COALESCE(v_hc_npf_gate, 40)
                AND v_life_credits_proj >= COALESCE(v_hc_credits_gate, 17500);
  v_hc_pts := CASE WHEN v_hc_qualified THEN v_hc_tier_points ELSE 0 END;

  v_auto_gain_mod := CASE WHEN v_auto_gain_proj >= v_auto_gain_min THEN 1.00 ELSE 0.60 END;
  v_fire_gain_mod := CASE WHEN v_fire_gain_proj >= v_fire_gain_min THEN 0.90 ELSE 0.60 END;
  v_fs_eligibility_mult := v_fs_pts / 225.0;

  SELECT
    COALESCE(SUM(amount) FILTER (WHERE comp_category = 'auto_new'), 0),
    COALESCE(SUM(amount) FILTER (WHERE comp_category = 'fire_new'), 0),
    COALESCE(SUM(amount) FILTER (WHERE comp_category = 'life_new'), 0),
    COALESCE(SUM(amount) FILTER (WHERE comp_category = 'health_new'), 0)
  INTO v_auto_nc_ytd, v_fire_nc_ytd, v_life_nc_ytd, v_health_nc_ytd
  FROM public.comp_recap
  WHERE agency_id = p_agency_id
    AND period_year = v_year
    AND is_scorecard_eligible = true;

  v_auto_eligible   := v_auto_nc_ytd * v_auto_gain_mod * v_fs_eligibility_mult;
  v_fire_eligible   := v_fire_nc_ytd * v_fire_gain_mod * v_fs_eligibility_mult;
  v_life_eligible   := v_life_nc_ytd;
  v_health_eligible := v_health_nc_ytd;
  v_total_eligible  := v_auto_eligible + v_fire_eligible + v_life_eligible + v_health_eligible;
  v_total_eligible_proj := v_total_eligible * v_pace_factor;

  v_total_pts := v_hc_pts + v_auto_best_pts + v_fire_best_pts + v_fs_pts;
  v_bonus_rate := LEAST(1.625, v_total_pts / 400.0);
  v_bonus_ytd := v_total_eligible * v_bonus_rate;
  v_bonus_projected := v_total_eligible_proj * v_bonus_rate;

  RETURN jsonb_build_object(
    'as_of_date',         p_as_of_date,
    'effective_as_of_date', v_effective_as_of,
    'snapshot_date',      v_snap.snapshot_date,
    'has_manual_overrides', v_has_overrides,
    'program_year',       v_year,
    'days_elapsed',       v_days_elapsed,
    'pace_factor',        round(v_pace_factor::numeric, 4),
    'bonus_projected',    round(v_bonus_projected::numeric, 2),
    'bonus_ytd',          round(v_bonus_ytd::numeric, 2),
    'last_year_bonus',    v_last_year_bonus,
    'bonus_rate',         round(v_bonus_rate::numeric, 4),
    'total_points',       round(v_total_pts::numeric, 1),
    'points_breakdown',   jsonb_build_object(
      'honor_club',  v_hc_pts,
      'auto_best',   round(v_auto_best_pts::numeric, 1),
      'fire_best',   round(v_fire_best_pts::numeric, 1),
      'fs_credits',  round(v_fs_pts::numeric, 1)
    ),
    'bucket_detail',      jsonb_build_object(
      'auto_production_points', round(v_auto_prod_pts::numeric, 1),
      'auto_gain_points',       round(v_auto_gain_pts::numeric, 1),
      'fire_production_points', round(v_fire_prod_pts::numeric, 1),
      'fire_gain_points',       round(v_fire_gain_pts::numeric, 1),
      'fs_credits_points',      round(v_fs_pts::numeric, 1),
      'hc_points',              v_hc_pts,
      'hc_qualified_projected', v_hc_qualified,
      'hc_career_tier',         v_career_tier,
      'hc_tier_points',         v_hc_tier_points
    ),
    'modifiers',          jsonb_build_object(
      'auto_gain_mod',       v_auto_gain_mod,
      'fire_gain_mod',       v_fire_gain_mod,
      'fs_eligibility_mult', round(v_fs_eligibility_mult::numeric, 4)
    ),
    'eligible_commissions', jsonb_build_object(
      'auto_nc_ytd',     round(v_auto_nc_ytd::numeric, 2),
      'fire_nc_ytd',     round(v_fire_nc_ytd::numeric, 2),
      'life_nc_ytd',     round(v_life_nc_ytd::numeric, 2),
      'health_nc_ytd',   round(v_health_nc_ytd::numeric, 2),
      'auto_eligible',   round(v_auto_eligible::numeric, 2),
      'fire_eligible',   round(v_fire_eligible::numeric, 2),
      'life_eligible',   round(v_life_eligible::numeric, 2),
      'health_eligible', round(v_health_eligible::numeric, 2),
      'total_eligible_ytd',        round(v_total_eligible::numeric, 2),
      'total_eligible_projected',  round(v_total_eligible_proj::numeric, 2)
    ),
    'inputs', jsonb_build_object(
      'auto_prod_ytd',     v_auto_prod_ytd,
      'auto_prod_proj',    round(v_auto_prod_proj::numeric, 1),
      'auto_gain_ytd',     v_auto_gain_ytd,
      'auto_gain_proj',    round(v_auto_gain_proj::numeric, 1),
      'fire_prod_ytd',     v_fire_prod_ytd,
      'fire_prod_proj',    round(v_fire_prod_proj::numeric, 1),
      'fire_gain_ytd',     v_fire_gain_ytd,
      'fire_gain_proj',    round(v_fire_gain_proj::numeric, 1),
      'life_npf_ytd',      v_life_npf_ytd,
      'life_npf_proj',     round(v_life_npf_proj::numeric, 1),
      'life_credits_ytd',  v_life_credits_ytd,
      'life_credits_proj', round(v_life_credits_proj::numeric, 2),
      'fs_credits_ytd',    v_fs_credits_ytd,
      'fs_credits_proj',   round(v_fs_credits_proj::numeric, 2)
    ),
    'computed_at', now()
  );
END;
$function$;
