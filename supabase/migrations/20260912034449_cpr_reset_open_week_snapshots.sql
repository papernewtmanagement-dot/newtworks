-- Peter ruling 2026-09-11: "the all-star and other goals should all compute live until the
-- week gets frozen."
--
-- The problem this solves. All-Star crossings, Trailblazer crossings and the MVP row are all
-- written ONCE, on Saturday night, and never revisited. audit_weekly_leaderboard_crossings
-- uses ON CONFLICT DO NOTHING, so it can add a crossing but never take one back. MVP
-- detection skips entirely when a row already exists for the week. So the moment a
-- teammate's sales points are corrected after week close, every one of those snapshots is
-- wrong, and the goals bonus that counts them pays the wrong amount. Week ending 2026-09-12:
-- Thomas held an All-Star badge, an MVP credit of 662.41 and an extra $10 on a week whose
-- real figure is 548.99, under the 650 floor.
--
-- The fix. Before the week is frozen, wipe this week's derived snapshots so the writer that
-- runs next rebuilds them from current data. Once the week is frozen — sent_to_team_at is
-- set, meaning the team has seen it — nothing is touched ever again.
--
-- Deliberately NOT reset:
--   * leaderboards. Those are permanent records. Deleting this week's record row would lose
--     the record it displaced, which is not recoverable. Left for a separate decision.
--   * mvp_history when a prize draw has already been taken for the week. mvp_prize_draws has
--     no foreign key to mvp_history, so rebuilding could hand a taken draw to a different
--     person. If draws exist, the MVP row stands and is reported back as skipped.
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
  v_as_deleted int := 0;
  v_tb_deleted int := 0;
  v_mvp_reset  boolean := false;
  v_mvp_note   text := 'no mvp row for this week';
  v_draws      int := 0;
BEGIN
  SELECT sent_to_team_at INTO v_sent_at
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('reset', false, 'reason', 'no weekly_cpr_reports row for week');
  END IF;

  -- Frozen. The team has already seen this week. Leave it exactly as it is.
  IF v_sent_at IS NOT NULL THEN
    RETURN jsonb_build_object('reset', false, 'reason', 'week is frozen', 'sent_to_team_at', v_sent_at);
  END IF;

  -- Step the running All-Star counts back by whatever this week contributed, then clear
  -- the rows. The audit that follows re-adds only what still clears the floor.
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
    'mvp_row_cleared', v_mvp_reset,
    'mvp_note', v_mvp_note,
    'ran_at', now()
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.reset_open_week_snapshots(uuid, date) TO anon, authenticated;
