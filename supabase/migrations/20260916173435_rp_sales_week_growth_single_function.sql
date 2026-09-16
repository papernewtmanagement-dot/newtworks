-- "This week's sales points = quarter-to-date now minus quarter-to-date last week"
-- was written out by hand in two separate places inside rp_week_scoreboard_for,
-- once for reported weeks and once for live weeks. Two copies of one rule drift.
-- It now lives here, in one function, and both branches call it. Peter 2026-09-16.
CREATE OR REPLACE FUNCTION public.rp_sales_week_growth(p_agency_id uuid, p_week_end date)
 RETURNS TABLE(team_member_id uuid, qtd numeric, prev numeric, growth numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH wk AS (SELECT public.rp_week_end(p_week_end) AS this_end),
  cur AS (SELECT x.team_id, x.sales_points
          FROM wk, public.get_sales_points_qtd(p_agency_id, wk.this_end) x),
  pri AS (SELECT x.team_id, x.sales_points
          FROM wk, public.get_sales_points_qtd(p_agency_id, wk.this_end - 7) x)
  SELECT COALESCE(c.team_id, p.team_id) AS team_member_id,
         COALESCE(c.sales_points, 0) AS qtd,
         COALESCE(p.sales_points, 0) AS prev,
         ROUND(COALESCE(c.sales_points, 0) - COALESCE(p.sales_points, 0), 2) AS growth
  FROM cur c FULL JOIN pri p ON p.team_id = c.team_id;
$function$;

-- Point both branches of the scoreboard at it.
DO $mig$
DECLARE
  v_def text;
  v_sp_old text := E'    sp AS (\n      SELECT tm,\n        (SELECT x.pts FROM sp_rows x WHERE x.tm = s.tm AND x.wk <= v_week_end ORDER BY x.wk DESC LIMIT 1) AS qtd,\n        COALESCE((SELECT x.pts FROM sp_rows x WHERE x.tm = s.tm AND x.wk <= v_prev_end ORDER BY x.wk DESC LIMIT 1), 0) AS prev\n      FROM (SELECT DISTINCT tm FROM sp_rows) s\n    ),\n';
  v_sp_new text := E'    -- One definition of the week''s growth, shared with the live branch.\n    sp AS (\n      SELECT g.team_member_id AS tm, g.qtd, g.prev, g.growth\n      FROM public.rp_sales_week_growth(p_agency_id, v_week_end) g\n    ),\n';
  v_filt_old text := E'          OR t.id IN (SELECT tm FROM sp WHERE ROUND(COALESCE(qtd, 0) - COALESCE(prev, 0), 2) <> 0)\n';
  v_filt_new text := E'          OR t.id IN (SELECT tm FROM sp WHERE COALESCE(growth, 0) <> 0)\n';
  v_pts_old text := E'          ''points'', ROUND(COALESCE(s.qtd, 0) - COALESCE(s.prev, 0), 2),\n';
  v_pts_new text := E'          ''points'', COALESCE(s.growth, 0),\n';
  v_prev_old text := E'      COALESCE(fz.sales_points, 0) AS prev_pts,\n';
  v_prev_new text := E'      COALESCE(g.growth, 0) AS week_growth,\n';
  v_join_old text := E'    LEFT JOIN public.get_sales_points_qtd(p_agency_id, v_prev_end) fz ON fz.team_id = r.id\n';
  v_join_new text := E'    LEFT JOIN public.rp_sales_week_growth(p_agency_id, v_week_end) g ON g.team_member_id = r.id\n';
  v_use_old text := E'        ''points'', ROUND(COALESCE((s.cur->''commission''->>''total_commission'')::numeric, 0) - COALESCE(s.prev_pts, 0), 2),\n';
  v_use_new text := E'        ''points'', COALESCE(s.week_growth, 0),\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rp_week_scoreboard_for';

  IF position('rp_sales_week_growth' IN v_def) > 0 THEN RAISE NOTICE 'already applied'; RETURN; END IF;
  IF position(v_sp_old IN v_def) = 0 OR position(v_filt_old IN v_def) = 0 OR position(v_pts_old IN v_def) = 0
     OR position(v_prev_old IN v_def) = 0 OR position(v_join_old IN v_def) = 0 OR position(v_use_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'scoreboard not in the expected shape - another thread changed rp_week_scoreboard_for';
  END IF;

  v_def := replace(v_def, v_sp_old,   v_sp_new);
  v_def := replace(v_def, v_filt_old, v_filt_new);
  v_def := replace(v_def, v_pts_old,  v_pts_new);
  v_def := replace(v_def, v_prev_old, v_prev_new);
  v_def := replace(v_def, v_join_old, v_join_new);
  v_def := replace(v_def, v_use_old,  v_use_new);
  EXECUTE v_def;
END $mig$;
