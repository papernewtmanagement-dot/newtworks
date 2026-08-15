CREATE OR REPLACE FUNCTION public.compute_wtw_requirements_adjustment(p_agency_id uuid, p_week_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_forward_only_cutoff CONSTANT date := '2026-08-01';
  v_rate CONSTANT numeric := 10;
  v_team_requirement int;
  v_team_raw int;
  v_team_net int;
  v_sp_qtd numeric;
  v_sp_target numeric;
  v_raw_pass boolean;
  v_sp_pass boolean;
  v_eligible boolean;
  v_team_gap int;
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

  SELECT COALESCE(quotes_fresh_needed, 0) + COALESCE(quotes_owed_carryover, 0),
         COALESCE(quarterly_sales_points_qtd, 0),
         COALESCE(quarterly_sales_points_target, 0)
  INTO v_team_requirement, v_sp_qtd, v_sp_target
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date;

  IF v_team_requirement IS NULL THEN
    RETURN jsonb_build_object(
      'active', false, 'reason', 'no weekly_cpr_reports row for this week',
      'team', jsonb_build_object('quotes_under', 0, 'dollars', 0),
      'restored_total', 0,
      'people', '[]'::jsonb);
  END IF;

  SELECT COALESCE(SUM(r.quotes_discussed), 0), COALESCE(SUM(r.net_quotes), 0)
  INTO v_team_raw, v_team_net
  FROM public.get_weekly_cpr_requirements(p_agency_id, p_week_end_date) r;

  -- Eligibility (locked 2026-08-15): the buy-back only applies when the team was actually on
  -- track to win the week before requirements touched anything — enough raw quotes AND enough
  -- sales points. If either was already short on raw numbers, there's nothing to buy back.
  v_raw_pass := v_team_raw >= v_team_requirement;
  v_sp_pass  := v_sp_qtd   >= v_sp_target;
  v_eligible := v_raw_pass AND v_sp_pass;

  v_team_gap := CASE WHEN v_raw_pass THEN GREATEST(0, v_team_requirement - v_team_net) ELSE 0 END;

  IF NOT v_eligible THEN
    RETURN jsonb_build_object(
      'active', true, 'week_end_date', p_week_end_date, 'rate', v_rate,
      'eligible', false, 'raw_pass', v_raw_pass, 'sp_pass', v_sp_pass,
      'team', jsonb_build_object(
        'requirement', v_team_requirement, 'raw', v_team_raw, 'net', v_team_net,
        'quotes_under', 0, 'dollars', 0, 'total_gap', v_team_gap, 'restored_by_individuals', 0),
      'restored_total', 0,
      'people', '[]'::jsonb);
  END IF;

  -- Step 1 (locked 2026-08-15): licensed individuals whose OWN raw quotes cleared their personal
  -- minimum, but whose net (post-requirements) fell short of it, pay $10/quote from their own
  -- share and get those specific quotes back — restoring their personal shortfall.
  WITH reqs AS (
    SELECT r.team_member_id, r.quotes_discussed, r.net_quotes
    FROM public.get_weekly_cpr_requirements(p_agency_id, p_week_end_date) r
  ),
  personal AS (
    SELECT
      t.id AS team_member_id,
      CASE
        WHEN t.role_level IN ('Account Manager','Unit Manager') AND t.role_category = 'Sales' THEN 15
        WHEN t.role_level IN ('Account Manager','Unit Manager') AND t.role_category = 'Retention' THEN 8
        ELSE NULL
      END AS personal_min
    FROM public.team t
    WHERE t.agency_id = p_agency_id AND t.category = 'agency' AND COALESCE(t.license_pc, false) = true
  ),
  per_person AS (
    SELECT
      reqs.team_member_id,
      p.personal_min,
      reqs.quotes_discussed,
      reqs.net_quotes,
      CASE
        WHEN p.personal_min IS NOT NULL AND reqs.quotes_discussed >= p.personal_min
          THEN ROUND(GREATEST(0, p.personal_min - reqs.net_quotes))::int
        ELSE 0
      END AS quotes_under
    FROM reqs
    JOIN personal p ON p.team_member_id = reqs.team_member_id
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'team_member_id', team_member_id,
      'quotes_under', quotes_under,
      'dollars', v_rate * quotes_under
    )) FILTER (WHERE quotes_under > 0), '[]'::jsonb),
    COALESCE(SUM(quotes_under), 0)
  INTO v_people, v_step1_restored
  FROM per_person;

  -- Step 2 (locked 2026-08-15): whatever team-level gap remains after individual buy-backs is
  -- regained by subtracting $10/quote from the shared team bonus pool — only the remainder,
  -- never double-charged against what individuals already bought back themselves.
  v_step2_restored := GREATEST(0, v_team_gap - v_step1_restored);
  v_step2_dollars   := v_rate * v_step2_restored;
  v_total_restored  := v_step1_restored + v_step2_restored;

  RETURN jsonb_build_object(
    'active', true,
    'week_end_date', p_week_end_date,
    'rate', v_rate,
    'eligible', true,
    'raw_pass', v_raw_pass,
    'sp_pass', v_sp_pass,
    'team', jsonb_build_object(
      'requirement', v_team_requirement, 'raw', v_team_raw, 'net', v_team_net,
      'quotes_under', v_step2_restored, 'dollars', v_step2_dollars,
      'total_gap', v_team_gap, 'restored_by_individuals', v_step1_restored),
    'restored_total', v_total_restored,
    'people', v_people
  );
END;
$function$;
