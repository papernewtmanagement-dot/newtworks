-- Returns Section 11 data for a given week. SMVC row is fully computed;
-- Scorecard Bonus row + budget lines are placeholders pending future work.

CREATE OR REPLACE FUNCTION public.get_cpr_section_11(
  p_agency_id uuid,
  p_week_ending_date date
) RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
AS $function$
DECLARE
  v_program_year      int := EXTRACT(YEAR FROM p_week_ending_date)::int;
  v_snap              record;
  v_smvc              jsonb;
  v_smvc_on_time      numeric;
  v_smvc_current      numeric;
  v_smvc_last_wk      numeric;
  v_smvc_last_q       numeric;
  v_smvc_dollar_diff  numeric;
  v_latest_history    record;
  v_production_basis  numeric;
  v_last_q_end        date;
  v_pc_production     numeric;
  v_auto_gain         numeric;
  v_fire_gain         numeric;
  v_fs_credits        numeric;
  v_ips_activity      numeric;
BEGIN
  -- Most recent sf_on_time_snapshot at or before week_ending
  SELECT * INTO v_snap
  FROM public.sf_on_time_snapshot
  WHERE agency_id = p_agency_id
    AND snapshot_date <= p_week_ending_date
  ORDER BY snapshot_date DESC
  LIMIT 1;

  IF FOUND THEN
    v_pc_production := COALESCE(v_snap.auto_production_ytd, 0) + COALESCE(v_snap.fire_production_ytd, 0);
    v_auto_gain     := COALESCE(v_snap.auto_production_ytd, 0) - COALESCE(v_snap.auto_lapse_ytd, 0);
    v_fire_gain     := COALESCE(v_snap.fire_production_ytd, 0) - COALESCE(v_snap.fire_lapse_ytd, 0);
    v_fs_credits    := COALESCE(v_snap.life_premium_credits_ytd, 0);
    v_ips_activity  := COALESCE(v_snap.ips_activity_ytd, 0);

    v_smvc := public.compute_on_time_smvc_with_better_of(
      p_agency_id, v_program_year,
      v_pc_production, v_auto_gain, v_fire_gain, v_fs_credits, v_ips_activity
    );
    v_smvc_on_time := (v_smvc->>'applied_smvc_decimal')::numeric;
  END IF;

  -- Latest smvc_history row for Current + Last Wk
  SELECT * INTO v_latest_history
  FROM public.smvc_history
  WHERE agency_id = p_agency_id
    AND as_of_date <= p_week_ending_date
  ORDER BY as_of_date DESC
  LIMIT 1;

  IF FOUND THEN
    v_smvc_current := v_latest_history.this_period_smvc;
    v_smvc_last_wk := v_latest_history.last_period_smvc;

    -- Back-derive annualized production basis from the row's known dollar_impact
    IF v_latest_history.dollar_impact IS NOT NULL
       AND v_latest_history.this_period_smvc IS NOT NULL
       AND v_latest_history.last_period_smvc IS NOT NULL
       AND (v_latest_history.this_period_smvc - v_latest_history.last_period_smvc) <> 0 THEN
      v_production_basis := v_latest_history.dollar_impact /
                            (v_latest_history.this_period_smvc - v_latest_history.last_period_smvc);
    END IF;
  END IF;

  -- Last Q = SMVC at end of prior quarter (most recent history row at or before)
  v_last_q_end := (date_trunc('quarter', p_week_ending_date)::date) - 1;
  SELECT this_period_smvc INTO v_smvc_last_q
  FROM public.smvc_history
  WHERE agency_id = p_agency_id
    AND as_of_date <= v_last_q_end
  ORDER BY as_of_date DESC
  LIMIT 1;

  -- Dollar diff = annualized (on_time - current) × production_basis
  IF v_smvc_on_time IS NOT NULL AND v_smvc_current IS NOT NULL AND v_production_basis IS NOT NULL THEN
    v_smvc_dollar_diff := (v_smvc_on_time - v_smvc_current) * v_production_basis;
  END IF;

  RETURN jsonb_build_object(
    'program_year',     v_program_year,
    'week_ending_date', p_week_ending_date,
    'snapshot_date',    v_snap.snapshot_date,
    'smvc', jsonb_build_object(
      'on_time',          v_smvc_on_time,
      'last_wk',          v_smvc_last_wk,
      'last_q',           v_smvc_last_q,
      'current',          v_smvc_current,
      'dollar_diff',      v_smvc_dollar_diff,
      'bands_complete',   COALESCE((v_smvc->>'bands_complete')::boolean, false),
      'production_basis', v_production_basis,
      'computed_breakdown', v_smvc
    ),
    'scorecard_bonus', jsonb_build_object(
      'on_time',     NULL,
      'last_wk',     NULL,
      'last_q',      NULL,
      'current',     NULL,
      'dollar_diff', NULL,
      'note',        'compute_scorecard_bonus() not yet built'
    ),
    'prize_cart_budget', jsonb_build_object('value', NULL, 'note', 'formula TBD'),
    'wtq_trip_budget',   jsonb_build_object('value', NULL, 'note', 'formula TBD'),
    'computed_at',       now()
  );
END;
$function$;
