-- Migration 032: Rewrite get_cpr_section_11 to remove smvc_history dependency.
-- Drops the LAST function reference to smvc_history (already dropped in migration 031).
-- Preserves the jsonb key shape that render_cpr_section_11_html expects:
--   smvc.on_time, smvc.last_wk, smvc.last_q, smvc.current, smvc.dollar_diff, smvc.bands_complete
--
-- Field mapping change:
--   on_time     = compute_on_time_smvc_with_better_of().applied_smvc_decimal  (unchanged)
--   current     = compute_on_time_smvc_with_better_of().capped_smvc_decimal   (was smvc_history.this_period_smvc)
--   last_wk     = NULL  (no longer tracked; was smvc_history.last_period_smvc — per-week snapshots no longer kept)
--   last_q      = NULL  (no longer tracked; was smvc_history row at prior-quarter end)
--   dollar_diff = (on_time - applied_currently_paying) × (auto_premium + fire_premium)
--                 where applied_currently_paying = agency.smvc_rate_pc and premium = latest book_snapshot
--
-- Tonight's Saturday email (23:59 CT 2026-06-20) renders this section. Last Wk + Last Q show "—".

CREATE OR REPLACE FUNCTION public.get_cpr_section_11(p_agency_id uuid, p_week_ending_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_program_year      int := EXTRACT(YEAR FROM p_week_ending_date)::int;
  v_snap              record;
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
  v_book              record;
BEGIN
  -- Most recent sf_on_time_snapshot at or before week_ending — inputs for runtime SMVC compute
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
    v_smvc_on_time := NULLIF(v_smvc->>'applied_smvc_decimal','')::numeric;
    v_smvc_current := NULLIF(v_smvc->>'capped_smvc_decimal','')::numeric;
  END IF;

  -- Currently-applied SMVC rate from agency (replaces smvc_history.last_period_smvc reads)
  SELECT smvc_rate_pc INTO v_smvc_applied
  FROM public.agency
  WHERE id = p_agency_id;

  -- P&C in-force premium from latest book_snapshot at or before week_ending
  SELECT auto_premium, fire_premium INTO v_book
  FROM public.book_snapshot
  WHERE agency_id = p_agency_id
    AND snapshot_date <= p_week_ending_date
  ORDER BY snapshot_date DESC
  LIMIT 1;

  IF FOUND THEN
    v_pc_premium := COALESCE(v_book.auto_premium, 0) + COALESCE(v_book.fire_premium, 0);
  END IF;

  -- Dollar diff = (on_time - currently-applied) × P&C in-force premium
  -- Represents the annualized commission delta if next year's applied rate locks at the current on-time pace.
  IF v_smvc_on_time IS NOT NULL AND v_smvc_applied IS NOT NULL AND v_pc_premium IS NOT NULL THEN
    v_smvc_dollar_diff := (v_smvc_on_time - v_smvc_applied) * v_pc_premium;
  END IF;

  RETURN jsonb_build_object(
    'program_year',     v_program_year,
    'week_ending_date', p_week_ending_date,
    'snapshot_date',    v_snap.snapshot_date,
    'smvc', jsonb_build_object(
      'on_time',          v_smvc_on_time,
      'last_wk',          NULL,                              -- smvc_history dropped 2026-06-20; per-week history no longer tracked
      'last_q',           NULL,                              -- smvc_history dropped 2026-06-20; quarter-end snapshots no longer tracked
      'current',          v_smvc_current,
      'applied',          v_smvc_applied,                    -- currently-paying rate from agency.smvc_rate_pc
      'dollar_diff',      v_smvc_dollar_diff,
      'bands_complete',   COALESCE((v_smvc->>'bands_complete')::boolean, false),
      'pc_premium_basis', v_pc_premium,
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
