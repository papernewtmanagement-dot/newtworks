-- Peter ruling 2026-09-11: a leaderboard record created in error for an open week gets
-- DELETED when the error is fixed. So the reset now also clears this week's ledger entries
-- and rebuilds the board. The audit that runs immediately after re-enters only what still
-- qualifies against current sales points. Anything that no longer qualifies simply stays
-- gone, and the record it had displaced comes back on its own.
--
-- quarter_sp entries carry a NULL record_week_ending and only get written at quarter close,
-- so they are matched by period label instead, and only when this week IS the quarter close.
CREATE OR REPLACE FUNCTION public.reset_open_week_snapshots(
  p_agency_id uuid,
  p_week_end_date date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sent_at    timestamptz;
  v_found      boolean;
  v_locked     boolean;
  v_as_deleted int := 0;
  v_tb_deleted int := 0;
  v_lb_deleted int := 0;
  v_mvp_reset  boolean := false;
  v_mvp_note   text := 'no mvp row for this week';
  v_draws      int := 0;
  v_cycle_end  date;
  v_qtr_label  text;
BEGIN
  SELECT true, sent_to_team_at INTO v_found, v_sent_at
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date;

  IF NOT COALESCE(v_found, false) THEN
    RETURN jsonb_build_object('reset', false, 'reason', 'no weekly_cpr_reports row for week');
  END IF;

  IF v_sent_at IS NOT NULL THEN
    RETURN jsonb_build_object('reset', false, 'reason', 'week is frozen - CPR already sent to the team',
                              'sent_to_team_at', v_sent_at);
  END IF;

  SELECT EXISTS (SELECT 1 FROM public.weekly_pool_lock wl
                 WHERE wl.agency_id = p_agency_id AND wl.week_end_date = p_week_end_date)
    INTO v_locked;

  IF v_locked THEN
    RETURN jsonb_build_object('reset', false, 'reason', 'week is frozen by payroll');
  END IF;

  UPDATE public.all_star_counts c
  SET count = GREATEST(0, c.count - x.n), updated_at = now()
  FROM (
    SELECT team_member_id, category, COUNT(*)::int AS n
    FROM public.all_star_crossings
    WHERE agency_id = p_agency_id AND week_ending = p_week_end_date
    GROUP BY team_member_id, category
  ) x
  WHERE c.agency_id = p_agency_id
    AND c.team_member_id = x.team_member_id
    AND c.category = x.category;

  WITH del AS (
    DELETE FROM public.all_star_crossings
    WHERE agency_id = p_agency_id AND week_ending = p_week_end_date
    RETURNING 1
  ) SELECT COUNT(*)::int INTO v_as_deleted FROM del;

  WITH del AS (
    DELETE FROM public.trailblazer_crossings
    WHERE agency_id = p_agency_id AND week_ending = p_week_end_date
    RETURNING 1
  ) SELECT COUNT(*)::int INTO v_tb_deleted FROM del;

  SELECT cci.cycle_end INTO v_cycle_end
  FROM public.current_cycle_info(p_agency_id, p_week_end_date) cci;
  v_qtr_label := 'Q' || EXTRACT(quarter FROM v_cycle_end)::text || ' ' || EXTRACT(year FROM v_cycle_end)::text;

  WITH del AS (
    DELETE FROM public.leaderboard_entries
    WHERE agency_id = p_agency_id
      AND (record_week_ending = p_week_end_date
           OR (category = 'quarter_sp'
               AND v_cycle_end = p_week_end_date
               AND record_period_label = v_qtr_label))
    RETURNING 1
  ) SELECT COUNT(*)::int INTO v_lb_deleted FROM del;

  IF v_lb_deleted > 0 THEN
    PERFORM public.rebuild_leaderboards_from_entries(p_agency_id);
  END IF;

  SELECT COUNT(*)::int INTO v_draws
  FROM public.mvp_prize_draws
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date;

  IF EXISTS (SELECT 1 FROM public.mvp_history
             WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date) THEN
    IF v_draws > 0 THEN
      v_mvp_note := 'kept - ' || v_draws || ' prize draw(s) already taken for this week';
    ELSE
      DELETE FROM public.mvp_history
      WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date;
      v_mvp_reset := true;
      v_mvp_note  := 'cleared for rebuild';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'reset', true,
    'week_end_date', p_week_end_date,
    'all_star_crossings_cleared', v_as_deleted,
    'trailblazer_crossings_cleared', v_tb_deleted,
    'leaderboard_entries_cleared', v_lb_deleted,
    'mvp_row_cleared', v_mvp_reset,
    'mvp_note', v_mvp_note,
    'ran_at', now()
  );
END;
$function$;