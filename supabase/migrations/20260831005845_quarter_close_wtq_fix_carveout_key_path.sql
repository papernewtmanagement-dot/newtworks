-- Fix: wtq_trip is a TOP-LEVEL key on compute_pool_carveouts, not nested under
-- carveouts_detail. (carveouts_detail is the key on compute_weekly_comp_residual_pool,
-- a different function.) The wrong path made v_wtq NULL, which silently drove every run
-- down the zero-pot branch and wrote $0 to everyone. Caught in a rolled-back test.
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
  WHERE t.end_date IS NULL;   -- given notice = out, per the handbook redemption rule

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

  v_mvp_dollars := ROUND(v_pot * 0.50, 2);
  v_rest_each   := CASE WHEN v_eligible > 1
                        THEN ROUND((v_pot - v_mvp_dollars) / (v_eligible - 1)::numeric, 2)
                        ELSE 0 END;

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
