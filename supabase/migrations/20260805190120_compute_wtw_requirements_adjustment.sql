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
  v_team_quotes_under int;
  v_team_dollars numeric;
  v_people jsonb;
BEGIN
  IF p_week_end_date <= v_forward_only_cutoff THEN
    RETURN jsonb_build_object(
      'active', false, 'reason', 'forward_only — first live week is week ending 2026-08-08',
      'team', jsonb_build_object('quotes_under', 0, 'dollars', 0),
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
      'people', '[]'::jsonb);
  END IF;

  SELECT COALESCE(SUM(r.quotes_discussed), 0), COALESCE(SUM(r.net_quotes), 0)
  INTO v_team_raw, v_team_net
  FROM public.get_weekly_cpr_requirements(p_agency_id, p_week_end_date) r;

  v_team_quotes_under := CASE WHEN v_team_raw >= v_team_requirement THEN GREATEST(0, v_team_requirement - v_team_net) ELSE 0 END;
  v_team_dollars := v_rate * v_team_quotes_under;

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
    WHERE t.agency_id = p_agency_id AND t.category = 'agency'
  ),
  per_person AS (
    SELECT
      reqs.team_member_id,
      p.personal_min,
      reqs.quotes_discussed,
      reqs.net_quotes,
      CASE
        WHEN p.personal_min IS NOT NULL AND reqs.quotes_discussed >= p.personal_min
          THEN GREATEST(0, p.personal_min - reqs.net_quotes)
        ELSE 0
      END AS quotes_under
    FROM reqs
    JOIN personal p ON p.team_member_id = reqs.team_member_id
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'team_member_id', team_member_id,
      'quotes_under', quotes_under,
      'dollars', v_rate * quotes_under
    )) FILTER (WHERE quotes_under > 0), '[]'::jsonb)
  INTO v_people
  FROM per_person;

  RETURN jsonb_build_object(
    'active', true,
    'week_end_date', p_week_end_date,
    'rate', v_rate,
    'team', jsonb_build_object(
      'requirement', v_team_requirement, 'raw', v_team_raw, 'net', v_team_net,
      'quotes_under', v_team_quotes_under, 'dollars', v_team_dollars),
    'people', v_people
  );
END;
$function$
