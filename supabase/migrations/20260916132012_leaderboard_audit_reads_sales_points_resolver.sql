-- audit_weekly_leaderboard_crossings had the same two faults as the live crossings
-- check: it read the typed-in sales points off the weekly report rows, and its
-- quarter figure SUMMED thirteen of those rows. Each row holds a running
-- quarter-to-date total, so adding them up inflated the quarter badly and could
-- stamp a leaderboard record that was never earned.
-- Both branches now go through sales_points_qtd_for. Patched by line range with a
-- shape guard so a change from another thread stops this rather than silently
-- overwriting it.
DO $migrate$
DECLARE
  v_def   text;
  v_lines text[];
  v_new   text;
  v_i     int;
  v_start int := 70;   -- WHEN 'week_sp' THEN
  v_end   int := 95;   -- close of the quarter_sp branch
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'audit_weekly_leaderboard_crossings';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'audit_weekly_leaderboard_crossings not found';
  END IF;

  v_lines := regexp_split_to_array(v_def, E'\n');

  IF v_lines[v_start] NOT LIKE '%WHEN ''week_sp'' THEN%' THEN
    RAISE EXCEPTION 'line % is not the week_sp branch (got: %) - another thread changed this function', v_start, v_lines[v_start];
  END IF;
  IF v_lines[v_end] NOT LIKE '%), 0)::numeric%' THEN
    RAISE EXCEPTION 'line % is not the close of the quarter_sp branch (got: %)', v_end, v_lines[v_end];
  END IF;
  IF v_lines[88] NOT LIKE '%SUM(d2.sales_points)%' THEN
    RAISE EXCEPTION 'expected the summed quarter figure on line 88, not found';
  END IF;

  v_new := '';
  FOR v_i IN 1 .. (v_start - 1) LOOP
    v_new := v_new || v_lines[v_i] || E'\n';
  END LOOP;

  v_new := v_new || E'          WHEN ''week_sp'' THEN\n'
    || E'            -- This week''s earnings: quarter-to-date now, less quarter-to-date a week ago.\n'
    || E'            GREATEST(0,\n'
    || E'              COALESCE((SELECT f.sales_points\n'
    || E'                          FROM public.sales_points_qtd_for(p_agency_id, p_week_end_date, t.id) f), 0)\n'
    || E'              - CASE WHEN (p_week_end_date - 7) >= v_quarter_start\n'
    || E'                     THEN COALESCE((SELECT f2.sales_points\n'
    || E'                                      FROM public.sales_points_qtd_for(p_agency_id, (p_week_end_date - 7), t.id) f2), 0)\n'
    || E'                     ELSE 0 END\n'
    || E'            )\n'
    || E'          WHEN ''four_week_sp'' THEN\n'
    || E'            public.compute_rolling_4wk_sp(p_agency_id, p_week_end_date, t.id)\n'
    || E'          WHEN ''quarter_sp'' THEN\n'
    || E'            -- The quarter figure is the quarter-to-date number at the close week,\n'
    || E'            -- not the sum of every week''s running total.\n'
    || E'            COALESCE((SELECT f.sales_points\n'
    || E'                        FROM public.sales_points_qtd_for(p_agency_id, v_cycle_end, t.id) f), 0)::numeric\n';

  FOR v_i IN (v_end + 1) .. array_length(v_lines, 1) LOOP
    v_new := v_new || v_lines[v_i] || E'\n';
  END LOOP;

  EXECUTE v_new;
END
$migrate$;
