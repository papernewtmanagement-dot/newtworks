-- (1) compute_retention_budget_weekly now pins as_of_date to the week_ending_date
--     so the SMVC inputs stop drifting with intraday days_elapsed changes.

CREATE OR REPLACE FUNCTION public.compute_retention_budget_weekly(
  p_agency_id        uuid,
  p_week_ending_date date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
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
  WHERE agency_id = p_agency_id
    AND snapshot_date <= p_week_ending_date
    AND auto_new_ytd IS NOT NULL
  ORDER BY snapshot_date DESC LIMIT 1;

  IF FOUND THEN
    v_smvc := public.compute_on_time_smvc_with_better_of(
      p_agency_id, v_program_year,
      COALESCE(v_ytd_snap.auto_new_ytd, 0) + COALESCE(v_ytd_snap.fire_new_ytd, 0),
      COALESCE(v_ytd_snap.auto_new_ytd, 0) - COALESCE(v_ytd_snap.auto_lost_ytd, 0),
      COALESCE(v_ytd_snap.fire_new_ytd, 0) - COALESCE(v_ytd_snap.fire_lost_ytd, 0),
      COALESCE(v_ytd_snap.life_paid_for_premium_ytd, 0),
      COALESCE(v_ytd_snap.ips_new_money_ytd, 0),
      p_week_ending_date     -- pin as_of_date to the week end so days_elapsed stops drifting
    );
    v_on_time_smvc   := NULLIF(v_smvc->>'applied_smvc_decimal','')::numeric;
    v_bands_complete := COALESCE((v_smvc->>'bands_complete')::boolean, false);
  END IF;

  SELECT auto_premium, fire_premium, life_premium INTO v_book_snap
  FROM public.agency_snapshot
  WHERE agency_id = p_agency_id
    AND snapshot_date <= p_week_ending_date
    AND auto_premium IS NOT NULL
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
    v_note := CASE WHEN v_on_time_smvc IS NULL  THEN 'missing on_time_SMVC inputs'
                   WHEN v_total_premium IS NULL THEN 'missing premium snapshot'
                   ELSE 'missing inputs' END;
  END IF;

  RETURN jsonb_build_object(
    'agency_id', p_agency_id, 'week_ending_date', p_week_ending_date,
    'budget', v_budget, 'phase', v_phase,
    'inputs', jsonb_build_object(
      'scheduled_multiplier', v_scheduled_multiplier,
      'on_time_smvc',         v_on_time_smvc,
      'on_time_smvc_source',  CASE WHEN v_smvc IS NOT NULL THEN v_smvc->>'better_of_source' END,
      'days_elapsed',         CASE WHEN v_smvc IS NOT NULL THEN (v_smvc->>'days_elapsed')::int END,
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
$$;
