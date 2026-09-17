-- get_weekly_crossings_live was reading the typed-in sales points straight off the
-- weekly report rows instead of asking the one calculator. Two consequences:
--   * the live week showed nothing new, because the typed-in number stops at the
--     last sent report;
--   * the quarter figure was SUMMING thirteen weekly rows, but those rows each hold
--     a running quarter-to-date total, not that week's earnings. Adding them up
--     inflated the quarter badly. The quarter figure is simply the quarter-to-date
--     number at the close week.
-- Both now come from sales_points_qtd_for, the same calculator every other screen uses.
CREATE OR REPLACE FUNCTION public.get_weekly_crossings_live(p_agency_id uuid, p_week_end_date date)
 RETURNS TABLE(kind text, category text, team_member_id uuid, value numeric, threshold numeric, tier integer, period_label text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
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
          -- This week's earnings: quarter-to-date now, less quarter-to-date a week ago.
          GREATEST(0,
            COALESCE((SELECT f.sales_points
                        FROM public.sales_points_qtd_for(p_agency_id, p_week_end_date, p.id) f), 0)
            - CASE WHEN (p_week_end_date - 7) >= v_cycle_start
                   THEN COALESCE((SELECT f2.sales_points
                                    FROM public.sales_points_qtd_for(p_agency_id, (p_week_end_date - 7), p.id) f2), 0)
                   ELSE 0 END
          )
        WHEN 'four_week_sp' THEN
          public.compute_rolling_4wk_sp(p_agency_id, p_week_end_date, p.id)
        WHEN 'quarter_sp' THEN
          COALESCE((SELECT f.sales_points
                      FROM public.sales_points_qtd_for(p_agency_id, v_cycle_end, p.id) f), 0)
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
