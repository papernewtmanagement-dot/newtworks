-- Single shared function for "team's actual quotes + sales points, latest submission
-- per person in a date window, any check-in type." Replaces four independently
-- duplicated copies of this SUM(DISTINCT ON...) query, three of which silently
-- excluded any check-in submitted during a health_eve (or morning) window from
-- the team total, even though those check-ins carry real quotes_week /
-- sales_points_quarter values (confirmed: every checkin_type always populates
-- both fields). Peter directive 2026-08-12: this must calculate the same way
-- regardless of which window someone checked in during, and it must live in
-- exactly one function.
CREATE OR REPLACE FUNCTION public.get_team_checkin_totals(
  p_agency_id uuid,
  p_period_start date,
  p_period_end date
)
RETURNS TABLE(total_quotes numeric, total_sales_points numeric)
LANGUAGE sql
STABLE
AS $function$
  SELECT
    COALESCE(SUM(latest_q), 0)  AS total_quotes,
    COALESCE(SUM(latest_sp), 0) AS total_sales_points
  FROM (
    SELECT DISTINCT ON (tc.team_id)
      tc.quotes_week AS latest_q,
      tc.sales_points_quarter AS latest_sp
    FROM public.team_checkins tc
    WHERE tc.agency_id = p_agency_id
      AND tc.checkin_date BETWEEN p_period_start AND p_period_end
    ORDER BY tc.team_id, tc.checkin_date DESC, tc.received_at DESC
  ) per_member;
$function$;

COMMENT ON FUNCTION public.get_team_checkin_totals IS
'Single source of truth for team quotes/SP totals from team_checkins. Takes each team member''s most recent check-in row (any checkin_type) within the window and sums quotes_week / sales_points_quarter across the team. Called by render_team_status_block, weekly_cpr_compute_outcome, weekly_cpr_upsert_in_progress, recompute_cpr_outcome. Do not re-duplicate this query — call this function.';
