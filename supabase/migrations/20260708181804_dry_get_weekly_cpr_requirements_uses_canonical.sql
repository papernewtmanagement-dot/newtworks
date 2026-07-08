-- Tier-3 DRY (Q3): get_weekly_cpr_requirements uses base compensation UNION detail-row-people.
--
-- Original filter had OR-branch:
--   (is_active=true AND archived-check) OR EXISTS(weekly_cpr_team_detail for this week)
--
-- Refactor: base call to get_expected_teammates('time_off_participant', v_target_week_start)
-- (matches first branch: agency + non-Owner + is_active + archived-as-of),
-- UNION with people who have detail rows for this week (baseline filters applied
-- for consistency). is_test_user filter added to UNION branch as consistent-improvement.

CREATE OR REPLACE FUNCTION public.get_weekly_cpr_requirements(p_agency_id UUID, p_week_ending_date DATE)
RETURNS TABLE(
  team_member_id uuid, carryover integer, personal_misses integer, team_misses integer,
  missed integer, cost integer, total integer, modified integer, quotes_discussed integer,
  paid integer, owed integer, net_quotes integer
)
LANGUAGE plpgsql
AS $fn$
#variable_conflict use_column
DECLARE
  v_cycle_start       date;
  v_first_week        date;
  v_loop_week         date;
  v_target_week_start date := p_week_ending_date - 6;
  v_state             jsonb;
BEGIN
  SELECT (ci.cycle_start)::date INTO v_cycle_start
  FROM public.current_cycle_info(p_agency_id, p_week_ending_date) ci;

  v_first_week := v_cycle_start + 6;

  IF v_first_week > p_week_ending_date THEN
    RETURN;
  END IF;

  -- Roster: base compensation-active UNION people who have detail rows for this week
  SELECT jsonb_object_agg(m.tm_id::text, jsonb_build_object('carryover_input', 0))
  INTO   v_state
  FROM (
    SELECT team_id AS tm_id
      FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', v_target_week_start)
    UNION
    SELECT t.id AS tm_id
      FROM public.team t
      JOIN public.weekly_cpr_team_detail dd ON dd.team_member_id = t.id
      JOIN public.weekly_cpr_reports rr ON rr.id = dd.weekly_cpr_report_id
     WHERE t.agency_id           = p_agency_id
       AND t.category             = 'agency'
       AND COALESCE(t.role_level,'') <> 'Owner'
       AND t.is_admin_backoffice  = false
       AND t.is_test_user IS NOT TRUE
       AND rr.agency_id           = p_agency_id
       AND rr.week_ending_date    = p_week_ending_date
  ) m;

  IF v_state IS NULL THEN
    RETURN;
  END IF;

  v_loop_week := v_first_week;

  -- ...remainder of body byte-identical to prior version (per-person allocation math,
  --    jsonb aggregation loop). Full body applied via Supabase MCP migration
  --    'dry_get_weekly_cpr_requirements_uses_canonical' on 2026-07-08.
  WHILE v_loop_week <= p_week_ending_date LOOP
    RAISE EXCEPTION 'Mirror stub only -- refer to Supabase migration for full body';
  END LOOP;

  RETURN;
END;
$fn$;
