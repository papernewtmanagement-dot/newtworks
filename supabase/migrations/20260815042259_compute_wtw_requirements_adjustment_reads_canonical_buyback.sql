CREATE OR REPLACE FUNCTION public.compute_wtw_requirements_adjustment(p_agency_id uuid, p_week_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_forward_only_cutoff CONSTANT date := '2026-08-01';
  v_rate CONSTANT numeric := 10;
  v_team_requirement int;
  v_team_raw int;
  v_team_net numeric;
  v_step1_restored int := 0;
  v_step2_restored int;
  v_step2_dollars numeric;
  v_total_restored int;
  v_people jsonb;
BEGIN
  IF p_week_end_date <= v_forward_only_cutoff THEN
    RETURN jsonb_build_object(
      'active', false, 'reason', 'forward_only — first live week is week ending 2026-08-08',
      'team', jsonb_build_object('quotes_under', 0, 'dollars', 0),
      'restored_total', 0,
      'people', '[]'::jsonb);
  END IF;

  SELECT COALESCE(quotes_fresh_needed, 0) + COALESCE(quotes_owed_carryover, 0)
  INTO v_team_requirement
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date;

  IF v_team_requirement IS NULL THEN
    RETURN jsonb_build_object(
      'active', false, 'reason', 'no weekly_cpr_reports row for this week',
      'team', jsonb_build_object('quotes_under', 0, 'dollars', 0),
      'restored_total', 0,
      'people', '[]'::jsonb);
  END IF;

  -- Individual buy-back (step 1) is now computed canonically inside get_weekly_cpr_requirements
  -- itself — its net_quotes already includes it, and it exposes the exact per-person amount via
  -- the 'buyback' column (locked 2026-08-15). No need to recompute personal-minimum eligibility
  -- here; just read it, sum it, and charge each person $10/quote. v_team_net below is therefore
  -- ALREADY net of step 1 — team_gap computed from it is exactly what step 2 (team pool) still
  -- owes, with zero risk of double-charging what individuals already bought back themselves.
  WITH reqs AS (
    SELECT r.team_member_id, r.quotes_discussed, r.buyback, r.net_quotes
    FROM public.get_weekly_cpr_requirements(p_agency_id, p_week_end_date) r
  )
  SELECT
    COALESCE(SUM(quotes_discussed), 0),
    COALESCE(SUM(net_quotes), 0),
    COALESCE(SUM(buyback), 0),
    COALESCE(jsonb_agg(jsonb_build_object(
      'team_member_id', team_member_id,
      'quotes_under', buyback,
      'dollars', v_rate * buyback
    )) FILTER (WHERE buyback > 0), '[]'::jsonb)
  INTO v_team_raw, v_team_net, v_step1_restored, v_people
  FROM reqs;

  v_step2_restored := GREATEST(0, v_team_requirement - v_team_net);
  v_step2_dollars   := v_rate * v_step2_restored;
  v_total_restored  := v_step1_restored + v_step2_restored;

  RETURN jsonb_build_object(
    'active', true,
    'week_end_date', p_week_end_date,
    'rate', v_rate,
    'eligible', (v_step1_restored > 0 OR v_step2_restored = GREATEST(0, v_team_requirement - v_team_net)),
    'team', jsonb_build_object(
      'requirement', v_team_requirement, 'raw', v_team_raw, 'net', v_team_net,
      'quotes_under', v_step2_restored, 'dollars', v_step2_dollars,
      'restored_by_individuals', v_step1_restored),
    'restored_total', v_total_restored,
    'people', v_people
  );
END;
$function$;
