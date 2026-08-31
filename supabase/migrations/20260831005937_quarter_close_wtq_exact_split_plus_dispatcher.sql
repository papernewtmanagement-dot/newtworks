-- 1) Exact split. Rounding each share independently left the paid total a cent off the
--    pot ($422.32 + $211.16 + $211.16 = $844.64 against a pot of $844.63). Round the even
--    shares, then let the MVP absorb the remainder so the paid total equals the carved-out
--    pot to the cent. Single-eligible-member case still pays only the 50% MVP half, per
--    the handbook — there is nobody to split the other half with.
CREATE OR REPLACE FUNCTION public.quarter_close_wtq(
  p_agency_id uuid,
  p_as_of     date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_as_of        date := COALESCE(p_as_of, (now() AT TIME ZONE 'America/Chicago')::date);
  v_cycle        record;
  v_cycle_start  date;
  v_cycle_end    date;
  v_wtq          jsonb;
  v_pot          numeric;
  v_halted       boolean;
  v_halt_reason  text;
  v_report_id    uuid;
  v_mvp_id       uuid;
  v_mvp_name     text;
  v_mvp_points   numeric;
  v_eligible     int;
  v_mvp_dollars  numeric := 0;
  v_rest_each    numeric := 0;
  v_rows         int := 0;
  v_detail       jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, v_as_of);
  v_cycle_start := v_cycle.cycle_start;
  v_cycle_end   := v_cycle.cycle_end;

  SELECT id INTO v_report_id
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = v_cycle_end;

  IF v_report_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false, 'reason', 'no CPR report for the final week of the quarter',
      'cycle_end', v_cycle_end, 'rows_written', 0);
  END IF;

  v_wtq := public.compute_pool_carveouts(p_agency_id, v_cycle_end) -> 'wtq_trip';

  IF v_wtq IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false, 'reason', 'compute_pool_carveouts returned no wtq_trip block',
      'cycle_end', v_cycle_end, 'rows_written', 0);
  END IF;

  v_pot         := COALESCE(NULLIF(v_wtq->>'quarterly_dollars','')::numeric, 0);
  v_halted      := COALESCE((v_wtq->>'halted')::boolean, false);
  v_halt_reason := v_wtq->>'halt_reason';

  CREATE TEMP TABLE IF NOT EXISTS _wtq_roster (
    team_id uuid, display_name text, quarter_points numeric) ON COMMIT DROP;
  DELETE FROM _wtq_roster;

  INSERT INTO _wtq_roster (team_id, display_name, quarter_points)
  SELECT et.team_id,
         COALESCE(et.display_name, et.first_name),
         COALESCE((SELECT SUM(COALESCE(d.sales_points, 0))
                   FROM public.weekly_cpr_team_detail d
                   JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
                   WHERE d.team_member_id = et.team_id
                     AND r.agency_id = p_agency_id
                     AND r.week_ending_date BETWEEN v_cycle_start AND v_cycle_end), 0)
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', v_cycle_end, NULL) et
  JOIN public.team t ON t.id = et.team_id
  WHERE t.end_date IS NULL;

  SELECT COUNT(*) INTO v_eligible FROM _wtq_roster;

  IF v_halted OR v_pot <= 0 OR v_eligible = 0 THEN
    UPDATE public.weekly_cpr_team_detail d
       SET wtq_trip_dollars = 0, wtq_quarter_mvp = false, updated_at = now()
     WHERE d.weekly_cpr_report_id = v_report_id;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN jsonb_build_object(
      'ok', true, 'trip_awarded', false,
      'reason', COALESCE(v_halt_reason,
                CASE WHEN v_eligible = 0 THEN 'no eligible team members'
                     ELSE 'trip pot is zero' END),
      'quarter', v_cycle.quarter_label, 'cycle_end', v_cycle_end,
      'pot_dollars', v_pot, 'rows_written', v_rows);
  END IF;

  SELECT team_id, display_name, quarter_points
    INTO v_mvp_id, v_mvp_name, v_mvp_points
  FROM _wtq_roster ORDER BY quarter_points DESC, display_name ASC LIMIT 1;

  IF v_eligible > 1 THEN
    v_rest_each   := ROUND(v_pot * 0.50 / (v_eligible - 1)::numeric, 2);
    v_mvp_dollars := v_pot - (v_rest_each * (v_eligible - 1));
  ELSE
    v_rest_each   := 0;
    v_mvp_dollars := ROUND(v_pot * 0.50, 2);
  END IF;

  UPDATE public.weekly_cpr_team_detail d
     SET wtq_trip_dollars = 0, wtq_quarter_mvp = false, updated_at = now()
   WHERE d.weekly_cpr_report_id = v_report_id;

  UPDATE public.weekly_cpr_team_detail d
     SET wtq_trip_dollars = CASE WHEN d.team_member_id = v_mvp_id
                                 THEN v_mvp_dollars ELSE v_rest_each END,
         wtq_quarter_mvp  = (d.team_member_id = v_mvp_id),
         updated_at       = now()
   WHERE d.weekly_cpr_report_id = v_report_id
     AND d.team_member_id IN (SELECT team_id FROM _wtq_roster);
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  SELECT jsonb_agg(jsonb_build_object(
           'name', r.display_name,
           'quarter_sales_points', r.quarter_points,
           'mvp', (r.team_id = v_mvp_id),
           'trip_dollars', CASE WHEN r.team_id = v_mvp_id THEN v_mvp_dollars ELSE v_rest_each END)
         ORDER BY r.quarter_points DESC)
    INTO v_detail FROM _wtq_roster r;

  RETURN jsonb_build_object(
    'ok', true, 'trip_awarded', true,
    'quarter', v_cycle.quarter_label, 'cycle_end', v_cycle_end,
    'pot_dollars', v_pot,
    'mvp', v_mvp_name, 'mvp_dollars', v_mvp_dollars,
    'mvp_quarter_sales_points', v_mvp_points,
    'rest_count', v_eligible - 1, 'rest_each_dollars', v_rest_each,
    'eligible_count', v_eligible, 'rows_written', v_rows,
    'who', v_detail);
END;
$function$;

-- 2) Dispatcher. Same shape as the other two quarter-close dispatchers: the cron fires
--    every Saturday 23:59 CT and only the Saturday that IS the cycle end does anything.
--    Never calendar-quarter maths — that is a week off.
CREATE OR REPLACE FUNCTION public.quarter_close_wtq_dispatcher(
  p_agency_id uuid,
  p_recipe_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_today_ct  date;
  v_cycle_end date;
  v_result    jsonb;
BEGIN
  v_today_ct  := (now() AT TIME ZONE 'America/Chicago')::date;
  v_cycle_end := (public.current_cycle_info(p_agency_id, v_today_ct)).cycle_end;

  IF v_today_ct <> v_cycle_end THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'not quarter-close week',
      'today_ct', v_today_ct, 'cycle_end', v_cycle_end, 'recipe_id', p_recipe_id,
      'records_processed', 0,
      'output_summary', 'Skipped: not quarter-close week (today=' || v_today_ct
                        || ', cycle_end=' || v_cycle_end || ')');
  END IF;

  v_result := public.quarter_close_wtq(p_agency_id, v_today_ct);

  RETURN v_result || jsonb_build_object(
    'records_processed', COALESCE((v_result->>'rows_written')::int, 0),
    'output_summary',
      CASE WHEN COALESCE((v_result->>'trip_awarded')::boolean, false)
           THEN 'Win the Quarter ' || COALESCE(v_result->>'quarter','')
                || ': pot $' || COALESCE(v_result->>'pot_dollars','0')
                || ' — MVP ' || COALESCE(v_result->>'mvp','?')
                || ' $' || COALESCE(v_result->>'mvp_dollars','0')
                || ', ' || COALESCE(v_result->>'rest_count','0')
                || ' teammate(s) at $' || COALESCE(v_result->>'rest_each_dollars','0')
                || ' each. Receipts required for reimbursement.'
           ELSE 'Win the Quarter ' || COALESCE(v_result->>'quarter','')
                || ': no trip — ' || COALESCE(v_result->>'reason','unknown')
      END);
END;
$function$;
