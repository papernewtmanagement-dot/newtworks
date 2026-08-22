-- Drop dependents in reverse dependency order
DROP FUNCTION IF EXISTS public.get_cpr_section_11(uuid, date);
DROP FUNCTION IF EXISTS public.compute_retention_budget_weekly(uuid, date);
DROP FUNCTION IF EXISTS public.compute_on_time_smvc_with_better_of(uuid, integer, numeric, numeric, numeric, numeric, numeric);
DROP FUNCTION IF EXISTS public.compute_on_time_smvc(uuid, integer, numeric, numeric, numeric, numeric, numeric);

-- =====================================================================
-- BASE: compute_on_time_smvc
-- Projects each YTD actual to an annual on-time pace via
--   on_time = ytd_actual × 365 / days_elapsed
-- then interpolates the on-time value against the annual Min/Max bands.
-- =====================================================================
CREATE FUNCTION public.compute_on_time_smvc(
  p_agency_id uuid,
  p_program_year integer,
  p_pc_production_actual numeric,
  p_auto_pif_gain numeric,
  p_fire_pif_gain numeric,
  p_fs_credits numeric,
  p_ips_activity numeric,
  p_as_of_date date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_auto_smvc numeric;
  v_fire_smvc numeric;
  v_fs_smvc numeric;
  v_ips_smvc numeric;
  v_calculated_pct numeric;
  v_bands_complete boolean := true;
  v_days_elapsed int;
  v_days_in_year int;
  v_annualization_factor numeric;
  v_auto_on_time numeric;
  v_fire_on_time numeric;
  v_fs_on_time numeric;
  v_ips_on_time numeric;
  rec record;
BEGIN
  -- Annualization factor: actual × (days_in_year / days_elapsed)
  v_days_in_year := (make_date(p_program_year + 1, 1, 1) - make_date(p_program_year, 1, 1))::int;
  v_days_elapsed := (p_as_of_date - make_date(p_program_year, 1, 1))::int + 1;

  IF v_days_elapsed <= 0 THEN
    -- Before program year starts: no annualization possible, treat as identity
    v_annualization_factor := 1.0;
  ELSIF v_days_elapsed >= v_days_in_year THEN
    -- Year complete or past: actuals ARE the annual values
    v_annualization_factor := 1.0;
  ELSE
    v_annualization_factor := v_days_in_year::numeric / v_days_elapsed::numeric;
  END IF;

  v_auto_on_time := COALESCE(p_auto_pif_gain, 0) * v_annualization_factor;
  v_fire_on_time := COALESCE(p_fire_pif_gain, 0) * v_annualization_factor;
  v_fs_on_time   := COALESCE(p_fs_credits, 0)   * v_annualization_factor;
  v_ips_on_time  := COALESCE(p_ips_activity, 0) * v_annualization_factor;

  FOR rec IN
    SELECT bucket_name, min_target AS min_threshold, max_target AS max_threshold, percent_available
    FROM public.sf_program_targets
    WHERE agency_id = p_agency_id
      AND program = 'smvc'
      AND program_year = p_program_year
      AND bucket_name IN ('auto_pif_gain','fire_pif_gain','fs_credits','ips_activity')
  LOOP
    IF rec.bucket_name = 'auto_pif_gain' THEN
      v_auto_smvc := public.smvc_bucket_score(v_auto_on_time, rec.min_threshold, rec.max_threshold, rec.percent_available);
    ELSIF rec.bucket_name = 'fire_pif_gain' THEN
      v_fire_smvc := public.smvc_bucket_score(v_fire_on_time, rec.min_threshold, rec.max_threshold, rec.percent_available);
    ELSIF rec.bucket_name = 'fs_credits' THEN
      v_fs_smvc := public.smvc_bucket_score(v_fs_on_time, rec.min_threshold, rec.max_threshold, rec.percent_available);
    ELSIF rec.bucket_name = 'ips_activity' THEN
      v_ips_smvc := public.smvc_bucket_score(v_ips_on_time, rec.min_threshold, rec.max_threshold, rec.percent_available);
    END IF;
  END LOOP;

  IF v_auto_smvc IS NULL OR v_fire_smvc IS NULL OR v_fs_smvc IS NULL OR v_ips_smvc IS NULL THEN
    v_bands_complete := false;
  END IF;

  v_calculated_pct := COALESCE(v_auto_smvc,0)
                    + COALESCE(v_fire_smvc,0)
                    + COALESCE(v_fs_smvc,0)
                    + COALESCE(v_ips_smvc,0);

  RETURN jsonb_build_object(
    'program_year',            p_program_year,
    'as_of_date',              p_as_of_date,
    'days_elapsed',            v_days_elapsed,
    'days_in_year',            v_days_in_year,
    'annualization_factor',    v_annualization_factor,
    'gate_passed',             true,
    'gate_min',                NULL,
    'pc_production_actual',    p_pc_production_actual,
    'buckets', jsonb_build_object(
      'auto_pif_gain', jsonb_build_object('ytd', p_auto_pif_gain, 'on_time', v_auto_on_time, 'earned_pct', v_auto_smvc),
      'fire_pif_gain', jsonb_build_object('ytd', p_fire_pif_gain, 'on_time', v_fire_on_time, 'earned_pct', v_fire_smvc),
      'fs_credits',    jsonb_build_object('ytd', p_fs_credits,    'on_time', v_fs_on_time,   'earned_pct', v_fs_smvc),
      'ips_activity',  jsonb_build_object('ytd', p_ips_activity,  'on_time', v_ips_on_time,  'earned_pct', v_ips_smvc)
    ),
    'calculated_smvc_pct',     v_calculated_pct,
    'calculated_smvc_decimal', v_calculated_pct / 100.0,
    'capped_smvc_decimal',     LEAST(0.03, v_calculated_pct / 100.0),
    'bands_complete',          v_bands_complete,
    'computed_at',             now()
  );
END;
$function$;

-- =====================================================================
-- WRAPPER: compute_on_time_smvc_with_better_of
-- Unchanged Better Of logic; passes p_as_of_date through to base.
-- (NOTE: the rolling-avg-includes-current bug is a separate item.)
-- =====================================================================
CREATE FUNCTION public.compute_on_time_smvc_with_better_of(
  p_agency_id uuid,
  p_program_year integer,
  p_pc_production_actual numeric,
  p_auto_pif_gain numeric,
  p_fire_pif_gain numeric,
  p_fs_credits numeric,
  p_ips_activity numeric,
  p_as_of_date date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_current jsonb;
  v_current_rate numeric;
  v_prior1 numeric;
  v_prior2 numeric;
  v_priors_used int := 0;
  v_avg_rate numeric;
  v_better_of_rate numeric;
  v_better_of_source text;
BEGIN
  v_current := public.compute_on_time_smvc(
    p_agency_id, p_program_year,
    p_pc_production_actual, p_auto_pif_gain, p_fire_pif_gain, p_fs_credits, p_ips_activity,
    p_as_of_date
  );
  v_current_rate := (v_current->>'capped_smvc_decimal')::numeric;

  SELECT smvc_rate_pc_prior_year, smvc_rate_pc_2_years_prior
    INTO v_prior1, v_prior2
  FROM public.agency
  WHERE id = p_agency_id;

  v_priors_used := (CASE WHEN v_prior1 IS NOT NULL THEN 1 ELSE 0 END)
                 + (CASE WHEN v_prior2 IS NOT NULL THEN 1 ELSE 0 END);

  IF v_priors_used >= 2 THEN
    v_avg_rate := (v_current_rate + v_prior1 + v_prior2) / 3.0;
  ELSIF v_priors_used = 1 THEN
    v_avg_rate := (v_current_rate + COALESCE(v_prior1, v_prior2)) / 2.0;
  ELSE
    v_avg_rate := v_current_rate;
  END IF;

  IF v_current_rate >= v_avg_rate THEN
    v_better_of_rate := LEAST(0.03, v_current_rate);
    v_better_of_source := 'current_year';
  ELSE
    v_better_of_rate := LEAST(0.03, v_avg_rate);
    v_better_of_source := 'rolling_average';
  END IF;

  RETURN v_current || jsonb_build_object(
    'prior_year_smvc',     v_prior1,
    'prior_2_year_smvc',   v_prior2,
    'priors_used_in_avg',  v_priors_used,
    'rolling_avg_smvc',    v_avg_rate,
    'applied_smvc_decimal', v_better_of_rate,
    'better_of_source',    v_better_of_source
  );
END;
$function$;

-- =====================================================================
-- compute_retention_budget_weekly — pass snapshot_date as as_of_date
-- =====================================================================
CREATE FUNCTION public.compute_retention_budget_weekly(p_agency_id uuid, p_week_ending_date date)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_program_year         int := EXTRACT(YEAR FROM p_week_ending_date)::int;
  v_scheduled_multiplier numeric;
  v_phase                text;
  v_ytd_snap             record;
  v_book_snap            record;
  v_smvc                 jsonb;
  v_on_time_smvc         numeric;
  v_bands_complete       boolean;
  v_auto_premium         numeric;
  v_fire_premium         numeric;
  v_life_premium         numeric;
  v_total_premium        numeric;
  v_combined_rate        numeric;
  v_budget               numeric;
  v_note                 text;
BEGIN
  SELECT multiplier, phase INTO v_scheduled_multiplier, v_phase
  FROM public.retention_budget_schedule
  WHERE agency_id = p_agency_id AND week_end_date = p_week_ending_date
  LIMIT 1;

  IF v_scheduled_multiplier IS NULL THEN
    RETURN jsonb_build_object(
      'agency_id', p_agency_id, 'week_ending_date', p_week_ending_date,
      'budget', NULL, 'note', 'no retention_budget_schedule row for this week',
      'computed_at', now()
    );
  END IF;

  SELECT * INTO v_ytd_snap
  FROM public.agency_snapshot
  WHERE agency_id = p_agency_id AND snapshot_date <= p_week_ending_date AND auto_new_ytd IS NOT NULL
  ORDER BY snapshot_date DESC LIMIT 1;

  IF FOUND THEN
    v_smvc := public.compute_on_time_smvc_with_better_of(
      p_agency_id, v_program_year,
      COALESCE(v_ytd_snap.auto_new_ytd, 0) + COALESCE(v_ytd_snap.fire_new_ytd, 0),
      COALESCE(v_ytd_snap.auto_new_ytd, 0) - COALESCE(v_ytd_snap.auto_lost_ytd, 0),
      COALESCE(v_ytd_snap.fire_new_ytd, 0) - COALESCE(v_ytd_snap.fire_lost_ytd, 0),
      COALESCE(v_ytd_snap.life_paid_for_premium_ytd, 0),
      COALESCE(v_ytd_snap.ips_new_money_ytd, 0),
      v_ytd_snap.snapshot_date
    );
    v_on_time_smvc   := NULLIF(v_smvc->>'applied_smvc_decimal','')::numeric;
    v_bands_complete := COALESCE((v_smvc->>'bands_complete')::boolean, false);
  END IF;

  SELECT auto_premium, fire_premium, life_premium INTO v_book_snap
  FROM public.agency_snapshot
  WHERE agency_id = p_agency_id AND snapshot_date <= p_week_ending_date AND auto_premium IS NOT NULL
  ORDER BY snapshot_date DESC LIMIT 1;

  IF FOUND THEN
    v_auto_premium := COALESCE(v_book_snap.auto_premium, 0);
    v_fire_premium := COALESCE(v_book_snap.fire_premium, 0);
    v_life_premium := COALESCE(v_book_snap.life_premium, 0);
    v_total_premium := v_auto_premium + v_fire_premium + v_life_premium;
  END IF;

  IF v_on_time_smvc IS NOT NULL AND v_total_premium IS NOT NULL THEN
    v_combined_rate := v_scheduled_multiplier + (0.21::numeric * v_on_time_smvc);
    v_budget        := v_combined_rate * v_total_premium;
  ELSE
    v_note := CASE
      WHEN v_on_time_smvc IS NULL  THEN 'missing on_time_SMVC inputs (no YTD snapshot)'
      WHEN v_total_premium IS NULL THEN 'missing premium snapshot'
      ELSE 'missing inputs'
    END;
  END IF;

  RETURN jsonb_build_object(
    'agency_id', p_agency_id, 'week_ending_date', p_week_ending_date,
    'budget', v_budget, 'phase', v_phase,
    'inputs', jsonb_build_object(
      'scheduled_multiplier', v_scheduled_multiplier,
      'on_time_smvc',         v_on_time_smvc,
      'on_time_smvc_source',  CASE WHEN v_smvc IS NOT NULL THEN v_smvc->>'better_of_source' END,
      'bands_complete',       v_bands_complete,
      'auto_premium',         v_auto_premium,
      'fire_premium',         v_fire_premium,
      'life_premium',         v_life_premium,
      'total_premium',        v_total_premium,
      'combined_rate',        v_combined_rate
    ),
    'note', v_note, 'computed_at', now()
  );
END;
$function$;

-- =====================================================================
-- get_cpr_section_11 — pass snapshot_date as as_of_date
-- =====================================================================
CREATE FUNCTION public.get_cpr_section_11(p_agency_id uuid, p_week_ending_date date)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_program_year      int := EXTRACT(YEAR FROM p_week_ending_date)::int;
  v_snap              record;
  v_book              record;
  v_smvc              jsonb;
  v_smvc_on_time      numeric;
  v_smvc_current      numeric;
  v_smvc_applied      numeric;
  v_smvc_dollar_diff  numeric;
  v_pc_premium        numeric;
  v_pc_production     numeric;
  v_auto_gain         numeric;
  v_fire_gain         numeric;
  v_fs_credits        numeric;
  v_ips_activity      numeric;
  v_scorecard         jsonb;
BEGIN
  SELECT * INTO v_snap
  FROM public.agency_snapshot
  WHERE agency_id = p_agency_id AND snapshot_date <= p_week_ending_date AND auto_new_ytd IS NOT NULL
  ORDER BY snapshot_date DESC LIMIT 1;

  IF FOUND THEN
    v_pc_production := COALESCE(v_snap.auto_new_ytd, 0) + COALESCE(v_snap.fire_new_ytd, 0);
    v_auto_gain     := COALESCE(v_snap.auto_new_ytd, 0) - COALESCE(v_snap.auto_lost_ytd, 0);
    v_fire_gain     := COALESCE(v_snap.fire_new_ytd, 0) - COALESCE(v_snap.fire_lost_ytd, 0);
    v_fs_credits    := COALESCE(v_snap.life_paid_for_premium_ytd, 0);
    v_ips_activity  := COALESCE(v_snap.ips_new_money_ytd, 0);

    v_smvc := public.compute_on_time_smvc_with_better_of(
      p_agency_id, v_program_year,
      v_pc_production, v_auto_gain, v_fire_gain, v_fs_credits, v_ips_activity,
      v_snap.snapshot_date
    );
    v_smvc_on_time := NULLIF(v_smvc->>'applied_smvc_decimal','')::numeric;
    v_smvc_current := NULLIF(v_smvc->>'capped_smvc_decimal','')::numeric;
  END IF;

  SELECT smvc_rate_pc INTO v_smvc_applied FROM public.agency WHERE id = p_agency_id;

  SELECT auto_premium, fire_premium INTO v_book
  FROM public.agency_snapshot
  WHERE agency_id = p_agency_id AND snapshot_date <= p_week_ending_date AND auto_premium IS NOT NULL
  ORDER BY snapshot_date DESC LIMIT 1;

  IF FOUND THEN
    v_pc_premium := COALESCE(v_book.auto_premium, 0) + COALESCE(v_book.fire_premium, 0);
  END IF;

  IF v_smvc_on_time IS NOT NULL AND v_smvc_applied IS NOT NULL AND v_pc_premium IS NOT NULL THEN
    v_smvc_dollar_diff := (v_smvc_on_time - v_smvc_applied) * v_pc_premium;
  END IF;

  v_scorecard := public.compute_scorecard_bonus(p_agency_id, p_week_ending_date);

  RETURN jsonb_build_object(
    'program_year',     v_program_year,
    'week_ending_date', p_week_ending_date,
    'snapshot_date',    v_snap.snapshot_date,
    'smvc', jsonb_build_object(
      'on_time',          v_smvc_on_time,
      'last_wk',          NULL,
      'last_q',           NULL,
      'current',          v_smvc_current,
      'applied',          v_smvc_applied,
      'dollar_diff',      v_smvc_dollar_diff,
      'bands_complete',   COALESCE((v_smvc->>'bands_complete')::boolean, false),
      'pc_premium_basis', v_pc_premium,
      'computed_breakdown', v_smvc
    ),
    'scorecard_bonus', jsonb_build_object(
      'on_time',     (v_scorecard->>'bonus_projected')::numeric,
      'last_wk',     NULL,
      'last_q',      NULL,
      'current',     (v_scorecard->>'bonus_ytd')::numeric,
      'dollar_diff', ((v_scorecard->>'bonus_projected')::numeric - (v_scorecard->>'bonus_ytd')::numeric),
      'bonus_rate',  (v_scorecard->>'bonus_rate')::numeric,
      'total_points',(v_scorecard->>'total_points')::numeric,
      'computed_breakdown', v_scorecard
    ),
    'prize_cart_budget', jsonb_build_object('value', NULL, 'note', 'formula TBD'),
    'wtq_trip_budget',   jsonb_build_object('value', NULL, 'note', 'formula TBD'),
    'computed_at',       now()
  );
END;
$function$;

-- Grants
GRANT EXECUTE ON FUNCTION public.compute_on_time_smvc(uuid, integer, numeric, numeric, numeric, numeric, numeric, date) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.compute_on_time_smvc_with_better_of(uuid, integer, numeric, numeric, numeric, numeric, numeric, date) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.compute_retention_budget_weekly(uuid, date) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_cpr_section_11(uuid, date) TO anon, authenticated;
