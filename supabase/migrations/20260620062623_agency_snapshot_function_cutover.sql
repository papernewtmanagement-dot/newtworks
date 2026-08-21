-- Cutover three functions to read from agency_snapshot with renamed columns.

-- ============================================================
-- 1) book_snapshot_weekly_alert
-- ============================================================
CREATE OR REPLACE FUNCTION public.book_snapshot_weekly_alert(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_today          DATE := CURRENT_DATE;
  v_target_sat     DATE;
  v_existing       public.agency_snapshot%ROWTYPE;
  v_mod_ref        TEXT;
  v_already_open   INTEGER;
  v_title          TEXT;
  v_message        TEXT;
  v_severity       TEXT;
  v_alert_count    INTEGER := 0;
BEGIN
  v_target_sat := v_today - ((EXTRACT(DOW FROM v_today)::int + 1) % 7);
  v_mod_ref := 'book_snapshot_weekly_alert:' || v_target_sat::text;

  SELECT COUNT(*) INTO v_already_open
  FROM public.alerts
  WHERE agency_id = p_agency_id
    AND module_reference = v_mod_ref
    AND COALESCE(is_resolved, false) = false;

  IF v_already_open > 0 THEN
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary',    'Alert already open for ' || v_target_sat::text || '; skipped.'
    );
  END IF;

  SELECT * INTO v_existing
  FROM public.agency_snapshot
  WHERE agency_id = p_agency_id
    AND snapshot_date = v_target_sat
    AND cadence = 'weekly'
  LIMIT 1;

  IF FOUND THEN
    v_title    := 'Confirm this week''s agency snapshot (' || to_char(v_target_sat, 'Mon DD') || ')';
    v_message  := 'Auto-import from the SF CRM Analytics email landed. Open Financials > Book of Business > Add snapshot manually to review and fill in YTD new/lost counts, life paid_for count + premium, and IPS new money. The form will pre-fill with the parsed stock values.';
    v_severity := 'info';
  ELSE
    v_title    := 'Enter this week''s agency snapshot (' || to_char(v_target_sat, 'Mon DD') || ')';
    v_message  := 'No row found for ' || to_char(v_target_sat, 'Mon DD, YYYY') || ' yet. Either the SF CRM Analytics email did not arrive / parse, or it has not been forwarded. Open Financials > Book of Business > Add snapshot manually to enter this week''s numbers.';
    v_severity := 'warning';
  END IF;

  INSERT INTO public.alerts (
    agency_id, alert_type, severity, title, message,
    module_reference, is_read, is_resolved, due_date, created_at
  ) VALUES (
    p_agency_id, 'book_snapshot_weekly', v_severity, v_title, v_message,
    v_mod_ref, false, false, v_target_sat, NOW()
  );

  v_alert_count := 1;

  RETURN jsonb_build_object(
    'records_processed', v_alert_count,
    'output_summary',    'Alert created for week ending ' || v_target_sat::text || ' (' || v_severity || ').'
  );
END;
$function$;

-- ============================================================
-- 2) get_cpr_section_11
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_cpr_section_11(p_agency_id uuid, p_week_ending_date date)
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
BEGIN
  -- Most recent agency_snapshot row WITH YTD data populated — inputs for runtime SMVC compute.
  SELECT * INTO v_snap
  FROM public.agency_snapshot
  WHERE agency_id = p_agency_id
    AND snapshot_date <= p_week_ending_date
    AND auto_new_ytd IS NOT NULL
  ORDER BY snapshot_date DESC
  LIMIT 1;

  IF FOUND THEN
    v_pc_production := COALESCE(v_snap.auto_new_ytd, 0) + COALESCE(v_snap.fire_new_ytd, 0);
    v_auto_gain     := COALESCE(v_snap.auto_new_ytd, 0) - COALESCE(v_snap.auto_lost_ytd, 0);
    v_fire_gain     := COALESCE(v_snap.fire_new_ytd, 0) - COALESCE(v_snap.fire_lost_ytd, 0);
    v_fs_credits    := COALESCE(v_snap.life_paid_for_premium_ytd, 0);
    v_ips_activity  := COALESCE(v_snap.ips_new_money_ytd, 0);

    v_smvc := public.compute_on_time_smvc_with_better_of(
      p_agency_id, v_program_year,
      v_pc_production, v_auto_gain, v_fire_gain, v_fs_credits, v_ips_activity
    );
    v_smvc_on_time := NULLIF(v_smvc->>'applied_smvc_decimal','')::numeric;
    v_smvc_current := NULLIF(v_smvc->>'capped_smvc_decimal','')::numeric;
  END IF;

  -- Currently-applied SMVC rate from agency
  SELECT smvc_rate_pc INTO v_smvc_applied
  FROM public.agency
  WHERE id = p_agency_id;

  -- P&C in-force premium from most recent agency_snapshot row (any row, regardless of YTD presence)
  SELECT auto_premium, fire_premium INTO v_book
  FROM public.agency_snapshot
  WHERE agency_id = p_agency_id
    AND snapshot_date <= p_week_ending_date
    AND auto_premium IS NOT NULL
  ORDER BY snapshot_date DESC
  LIMIT 1;

  IF FOUND THEN
    v_pc_premium := COALESCE(v_book.auto_premium, 0) + COALESCE(v_book.fire_premium, 0);
  END IF;

  IF v_smvc_on_time IS NOT NULL AND v_smvc_applied IS NOT NULL AND v_pc_premium IS NOT NULL THEN
    v_smvc_dollar_diff := (v_smvc_on_time - v_smvc_applied) * v_pc_premium;
  END IF;

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

-- ============================================================
-- 3) compose_weekly_cpr_html  (point Agency Performance v_snap query at agency_snapshot)
-- ============================================================
-- Surgical patch: only the Agency Performance section's table/column references change.
-- Rest of function is unchanged. Use replace() against the existing definition.
DO $patch$
DECLARE
  v_orig text;
  v_new  text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_orig
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'compose_weekly_cpr_html';

  v_new := v_orig;

  -- Swap table reference for v_snap fetch
  v_new := replace(v_new,
    E'SELECT * INTO v_snap\n  FROM public.sf_on_time_snapshot\n  WHERE agency_id = p_agency_id AND snapshot_date <= p_week_ending_date\n  ORDER BY snapshot_date DESC LIMIT 1;',
    E'SELECT * INTO v_snap\n  FROM public.agency_snapshot\n  WHERE agency_id = p_agency_id AND snapshot_date <= p_week_ending_date\n    AND auto_new_ytd IS NOT NULL\n  ORDER BY snapshot_date DESC LIMIT 1;'
  );

  -- Column renames inside the Agency Performance block
  v_new := replace(v_new, 'v_snap.auto_production_ytd',     'v_snap.auto_new_ytd');
  v_new := replace(v_new, 'v_snap.auto_lapse_ytd',          'v_snap.auto_lost_ytd');
  v_new := replace(v_new, 'v_snap.fire_production_ytd',     'v_snap.fire_new_ytd');
  v_new := replace(v_new, 'v_snap.fire_lapse_ytd',          'v_snap.fire_lost_ytd');
  v_new := replace(v_new, 'v_snap.life_production_ytd',     'v_snap.life_new_ytd');
  v_new := replace(v_new, 'v_snap.life_loss_ytd',           'v_snap.life_lost_ytd');
  v_new := replace(v_new, 'v_snap.life_paid_count_ytd',     'v_snap.life_paid_for_count_ytd');
  v_new := replace(v_new, 'v_snap.life_premium_credits_ytd','v_snap.life_paid_for_premium_ytd');

  IF v_new = v_orig THEN
    RAISE EXCEPTION 'compose_weekly_cpr_html patch produced no changes — original may have shifted';
  END IF;

  EXECUTE v_new;
  RAISE NOTICE 'compose_weekly_cpr_html patched: % chars changed', length(v_new) - length(v_orig);
END $patch$;
