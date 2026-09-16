-- The week's sales points are quarter-to-date now minus quarter-to-date last week.
-- The "last week" side was being RECOMPUTED from production instead of read from
-- the frozen figure that was actually reported. So anything backfilled with an
-- issue date in an earlier week slid into the baseline and its points never showed
-- up as growth in any week. Now it reads the frozen resolver, the same source the
-- reported weeks already use. Peter 2026-09-16.
DO $mig$
DECLARE
  v_def text;
  v_prev_old text := E'      COALESCE(pv.sp, public.compute_sp_from_production(0, 0, 0, 0, 0, 0)) AS prev,\n';
  v_prev_new text := E'      -- Last week''s quarter-to-date as REPORTED, not recomputed (Peter 2026-09-16).\n'
                  || E'      COALESCE(fz.sales_points, 0) AS prev_pts,\n';
  v_join_old text := E'    LEFT JOIN public.production_sales_points_for(p_agency_id, v_cycle_start, v_prev_end) pv ON pv.team_member_id = r.id\n';
  v_join_new text := E'    LEFT JOIN public.get_sales_points_qtd(p_agency_id, v_prev_end) fz ON fz.team_id = r.id\n';
  v_use_old text := E'COALESCE((s.prev->''commission''->>''total_commission'')::numeric, 0), 2),';
  v_use_new text := E'COALESCE(s.prev_pts, 0), 2),';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rp_week_scoreboard_for';

  IF position('prev_pts' IN v_def) > 0 THEN RAISE NOTICE 'already applied'; RETURN; END IF;
  IF position(v_prev_old IN v_def) = 0 OR position(v_join_old IN v_def) = 0 OR position(v_use_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'sales prev block not in the expected shape - another thread changed rp_week_scoreboard_for';
  END IF;

  v_def := replace(v_def, v_prev_old, v_prev_new);
  v_def := replace(v_def, v_join_old, v_join_new);
  v_def := replace(v_def, v_use_old,  v_use_new);
  EXECUTE v_def;
END $mig$;
