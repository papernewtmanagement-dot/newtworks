-- Live recompute of this week's All-Star / Trailblazer / leaderboard chips.
--
-- WHY: the banner on CPRDetail read all_star_crossings.value_at_crossing,
-- trailblazer_crossings.value_at_crossing and leaderboards.record_value. Those are
-- snapshots written once on Saturday night by audit_weekly_leaderboard_crossings.
-- When a teammate's sales points get corrected afterward the snapshot does not move,
-- so the banner keeps showing a number and a badge that are no longer true. Week
-- ending 2026-09-12 showed Thomas at 662.41 weekly sales points with an All-Star
-- badge; his real weekly figure after the correction is 548.99, below the 650 floor.
--
-- Peter standing policy (2026-08-30, extended 2026-09-11): totals are computed on
-- display from the underlying rows, never read back from a stored column.
--
-- The value math here is copied from audit_weekly_leaderboard_crossings so the live
-- read and the writer agree. Only the reading changes; nothing is written.
CREATE OR REPLACE FUNCTION public.get_weekly_crossings_live(
  p_agency_id uuid,
  p_week_end_date date
)
RETURNS TABLE(
  kind text,
  category text,
  team_member_id uuid,
  value numeric,
  threshold numeric,
  tier integer,
  period_label text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_cycle_start      date;
  v_cycle_end        date;
  v_is_quarter_close boolean;
  v_report_id        uuid;
BEGIN
  SELECT cci.cycle_start, cci.cycle_end
    INTO v_cycle_start, v_cycle_end
  FROM public.current_cycle_info(p_agency_id, p_week_end_date) cci;

  v_is_quarter_close := (v_cycle_end = p_week_end_date);

  SELECT id INTO v_report_id
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date;

  IF v_report_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH cfg AS (
    SELECT c.category, c.round_step
    FROM public.leaderboard_floor_config c
    WHERE c.category <> 'quarter_sp' OR v_is_quarter_close
  ),
  bounds AS (
    SELECT
      cfg.category,
      COALESCE(FLOOR(b.record_value / cfg.round_step) * cfg.round_step, 0) AS floor_val,
      COALESCE(CEIL((g.record_value + 0.01) / cfg.round_step) * cfg.round_step, 0) AS tb_thresh
    FROM cfg
    LEFT JOIN public.leaderboards b
      ON b.agency_id = p_agency_id AND b.category = cfg.category AND b.tier = 3
    LEFT JOIN public.leaderboards g
      ON g.agency_id = p_agency_id AND g.category = cfg.category AND g.tier = 1
  ),
  people AS (
    SELECT t.id
    FROM public.team t
    WHERE t.agency_id = p_agency_id
      AND t.is_active = true
      AND t.archived_at IS NULL
      AND t.is_admin_backoffice = false
      AND (t.is_test_user IS NOT TRUE)
  ),
  vals AS (
    SELECT
      cfg.category,
      p.id AS tm_id,
      CASE cfg.category
        WHEN 'week_quotes' THEN
          COALESCE(
            (SELECT req.net_quotes
               FROM public.get_weekly_cpr_requirements(p_agency_id, p_week_end_date) req
              WHERE req.team_member_id = p.id
              LIMIT 1),
            0)::numeric
        WHEN 'week_sp' THEN
          GREATEST(0,
            COALESCE(
              (SELECT d.sales_points
                 FROM public.weekly_cpr_team_detail d
                WHERE d.weekly_cpr_report_id = v_report_id
                  AND d.team_member_id = p.id
                LIMIT 1),
              0)::numeric
            - COALESCE(
                (SELECT d2.sales_points
                   FROM public.weekly_cpr_team_detail d2
                   JOIN public.weekly_cpr_reports r2 ON r2.id = d2.weekly_cpr_report_id
                  WHERE r2.agency_id = p_agency_id
                    AND d2.team_member_id = p.id
                    AND r2.week_ending_date < p_week_end_date
                    AND r2.week_ending_date >= v_cycle_start
                  ORDER BY r2.week_ending_date DESC
                  LIMIT 1),
                0)::numeric
          )
        WHEN 'four_week_sp' THEN
          public.compute_rolling_4wk_sp(p_agency_id, p_week_end_date, p.id)
        WHEN 'quarter_sp' THEN
          COALESCE(
            (SELECT SUM(d2.sales_points)
               FROM public.weekly_cpr_team_detail d2
               JOIN public.weekly_cpr_reports r2 ON r2.id = d2.weekly_cpr_report_id
              WHERE r2.agency_id = p_agency_id
                AND d2.team_member_id = p.id
                AND r2.week_ending_date > (v_cycle_end - INTERVAL '13 weeks')::date
                AND r2.week_ending_date <= v_cycle_end),
            0)::numeric
      END AS the_value
    FROM cfg CROSS JOIN people p
  )
  -- All-Star: cleared the bronze floor this week.
  SELECT 'all_star'::text, v.category, v.tm_id, v.the_value, b.floor_val, NULL::integer,
         to_char(p_week_end_date, 'Mon DD, YYYY')::text
  FROM vals v JOIN bounds b ON b.category = v.category
  WHERE b.floor_val > 0 AND v.the_value >= b.floor_val

  UNION ALL
  -- Trailblazer: cleared the current gold record this week.
  SELECT 'trailblazer'::text, v.category, v.tm_id, v.the_value, b.tb_thresh, NULL::integer,
         to_char(p_week_end_date, 'Mon DD, YYYY')::text
  FROM vals v JOIN bounds b ON b.category = v.category
  WHERE b.tb_thresh > 0 AND v.the_value >= b.tb_thresh

  UNION ALL
  -- Leaderboard record set this week — the record row stays where it is, but the
  -- number shown is recomputed from the rows as they stand now.
  SELECT 'leaderboard'::text, l.category, l.team_member_id,
         COALESCE(v.the_value, l.record_value), NULL::numeric, l.tier,
         l.record_period_label
  FROM public.leaderboards l
  LEFT JOIN vals v ON v.category = l.category AND v.tm_id = l.team_member_id
  WHERE l.agency_id = p_agency_id
    AND l.record_week_ending = p_week_end_date;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_weekly_crossings_live(uuid, date) TO anon, authenticated;

-- Data correction applied in the same session (2026-09-11, week ending 2026-09-12 still open,
-- nothing paid yet): deleted the stale all_star_crossings row for Thomas Lynch
-- (893c77db-1d39-4870-8433-434d9ba07b84, category week_sp, value_at_crossing 662.41,
-- floor_at_crossing 650), stepped his all_star_counts.week_sp count back from 1 to 0, and
-- re-ran write_weekly_comp_v2 for the week. His goals_bonus went 30 -> 20 (Win the Week 10
-- plus 1% Gain 10; the All-Star 10 came off). Left as history, not re-applied here.
