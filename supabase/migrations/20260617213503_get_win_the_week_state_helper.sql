-- Helper: returns the LIVE Win the Week target state for any moment in time.
-- Used by both work-checkin compile messages and the morning recap.

CREATE OR REPLACE FUNCTION public.get_win_the_week_state(p_agency_id uuid, p_today date DEFAULT NULL)
RETURNS TABLE (
  week_of_cycle int,
  week_ending_saturday date,
  count_am_sales int,
  count_am_retention int,
  quotes_fresh_needed int,
  quotes_carryover int,
  quotes_target_total int,
  sp_target numeric
)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'extensions'
AS $func$
DECLARE
  v_today date;
  v_cycle record;
  v_am_sales int := 0;
  v_am_retention int := 0;
  v_carryover int := 0;
BEGIN
  v_today := COALESCE(p_today, (now() AT TIME ZONE 'America/Chicago')::date);
  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, v_today);

  SELECT
    count(*) FILTER (WHERE role_level = 'Account Manager' AND role_category = 'Sales'),
    count(*) FILTER (WHERE role_level = 'Account Manager' AND role_category = 'Retention')
  INTO v_am_sales, v_am_retention
  FROM public.team
  WHERE agency_id = p_agency_id AND archived_at IS NULL AND is_test_user IS NOT TRUE
    AND (include_in_team_checkins = true OR
         (include_in_team_checkins IS NULL AND category = 'agency' AND role != 'Owner'));

  SELECT COALESCE(quotes_owed_next_week, 0) INTO v_carryover
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = v_cycle.prior_week_ending_saturday;
  v_carryover := COALESCE(v_carryover, 0);

  week_of_cycle := v_cycle.week_of_cycle;
  week_ending_saturday := v_cycle.week_ending_saturday;
  count_am_sales := v_am_sales;
  count_am_retention := v_am_retention;
  quotes_fresh_needed := (15 * v_am_sales) + (8 * v_am_retention);
  quotes_carryover := v_carryover;
  quotes_target_total := quotes_fresh_needed + v_carryover;
  sp_target := v_cycle.week_of_cycle * ((1000 * v_am_sales) + (500 * v_am_retention));

  RETURN NEXT;
END;
$func$;

-- Verify against today
SELECT * FROM public.get_win_the_week_state('126794dd-25ff-47d2-a436-724499733365'::uuid);
