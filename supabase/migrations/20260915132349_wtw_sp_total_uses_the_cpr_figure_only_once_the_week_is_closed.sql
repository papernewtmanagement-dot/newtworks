-- The Win the Week sales-point total preferred the stored figure on the weekly
-- CPR report whenever won_the_week was NOT NULL. The row for the week in
-- progress is created on the Monday with won_the_week = false, so the test
-- passed on day one and the block showed last week's frozen quarter total all
-- week. On 2026-09-15 it read 4,527 while the live figure was 4,641.
-- The stored figure is now used only once the week has actually ended. During
-- the week it comes from get_sales_points_qtd, the one source.
CREATE OR REPLACE FUNCTION public.render_wtw_block(p_agency_id uuid, p_as_of_date date, p_prefix text, p_show_outcome boolean DEFAULT false)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_cycle record; v_wtw record; v_board jsonb;
  v_today_real date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_current_cycle record; v_week_closed boolean;
  v_ttq numeric := 0; v_tts numeric := 0;
  v_outcome record; v_outcome_text text := ''; v_text text;
BEGIN
  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, p_as_of_date);
  SELECT * INTO v_wtw FROM public.get_win_the_week_state(p_agency_id, p_as_of_date);
  SELECT * INTO v_current_cycle FROM public.current_cycle_info(p_agency_id, v_today_real);

  v_week_closed := v_cycle.week_ending_saturday < v_current_cycle.week_ending_saturday;

  v_board := public.rp_week_scoreboard_for(p_agency_id, v_cycle.week_ending_saturday);
  v_ttq := COALESCE((v_board->'team'->>'quotes')::numeric, 0);

  SELECT COALESCE((
    SELECT r.quarterly_sales_points_qtd FROM public.weekly_cpr_reports r
    WHERE r.agency_id = p_agency_id AND r.week_ending_date = v_cycle.week_ending_saturday
      AND v_week_closed AND r.won_the_week IS NOT NULL
  ), (
    SELECT COALESCE(SUM(s.sales_points), 0)
    FROM public.get_sales_points_qtd(p_agency_id, v_cycle.week_ending_saturday) s
  ), 0) INTO v_tts;

  IF p_show_outcome THEN
    SELECT won_the_week, COALESCE(quotes_owed_next_week, 0) AS carryover INTO v_outcome
    FROM public.weekly_cpr_reports
    WHERE agency_id = p_agency_id AND week_ending_date = v_cycle.week_ending_saturday;
    IF v_outcome.won_the_week IS TRUE  THEN v_outcome_text := ' 🏆 Won'; END IF;
    IF v_outcome.won_the_week IS FALSE THEN v_outcome_text := ' ❌ Missed'; END IF;
    IF v_outcome_text <> '' AND v_outcome.carryover > 0 THEN
      v_outcome_text := v_outcome_text
        || format(' (+%s %s into this week)', v_outcome.carryover, public.lbl_quotes());
    END IF;
  END IF;

  v_text := p_prefix || ' WtW ' || v_wtw.week_of_cycle || v_outcome_text
    || ', Ends ' || to_char(v_wtw.week_ending_saturday, 'Mon DD')
    || ', ' || to_char(p_as_of_date, 'Mon DD') || ':' || E'\n';

  v_text := v_text || '• ' || public.lbl_quotes() || ': '
    || v_ttq::text || '/' || v_wtw.quotes_target_total::text;
  IF v_ttq >= v_wtw.quotes_target_total THEN v_text := v_text || ' ✅';
  ELSE v_text := v_text || ' 🔻' || GREATEST(0, v_wtw.quotes_target_total - v_ttq::int)::text; END IF;
  IF v_wtw.quotes_carryover > 0 THEN
    v_text := v_text || ' (+' || v_wtw.quotes_carryover::text || ' carryover)';
  END IF;

  v_text := v_text || E'\n• SP: ' || to_char(v_tts, 'FM999G999G999')
    || '/' || to_char(v_wtw.sp_target, 'FM999G999G999');
  IF v_tts >= v_wtw.sp_target THEN v_text := v_text || ' ✅';
  ELSE v_text := v_text || ' 🔻' || to_char(GREATEST(0, v_wtw.sp_target - v_tts), 'FM999G999G999'); END IF;

  RETURN v_text;
END;
$function$;
