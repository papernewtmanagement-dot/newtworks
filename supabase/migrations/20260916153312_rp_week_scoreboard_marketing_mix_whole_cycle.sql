-- The quarter-to-date marketing breakdown only saw events from the week the
-- capture module went live, so anything logged in an earlier week of the quarter
-- was invisible and the whole quarter collapsed into one "reported" line.
-- The event CTEs now span the whole cycle, so every logged event is itemised.
-- Points are unchanged: qtd_live still counts live weeks only, and the reported
-- line becomes the REMAINDER of the weekly report that no logged event explains.
-- Peter 2026-09-16.
DO $mig$
DECLARE
  v_def text;
  v_n int;
  v_agg_old text := E'  m_agg AS (\n    SELECT tm,\n           SUM(points) FILTER (WHERE wk = v_week_end) AS points,\n           SUM(points) AS qtd_live,\n';
  v_agg_new text := E'  m_agg AS (\n    SELECT tm,\n           SUM(points) FILTER (WHERE wk = v_week_end) AS points,\n'
                 || E'           SUM(points) FILTER (WHERE wk >= v_live_from) AS qtd_live,\n'
                 || E'           -- What our own prices account for inside the already-reported weeks.\n'
                 || E'           SUM(points) FILTER (WHERE wk < v_live_from) AS priced_reported,\n';
  v_rep_old text := E'''qtd_mix'', COALESCE(mx.mix, ''[]''::jsonb), ''qtd_reported'', COALESCE(mr.points, 0),';
  v_rep_new text := E'''qtd_mix'', COALESCE(mx.mix, ''[]''::jsonb),\n        ''qtd_reported'', ROUND(COALESCE(mr.points, 0) - COALESCE(m.priced_reported, 0), 2),';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rp_week_scoreboard_for';

  IF position('priced_reported' IN v_def) > 0 THEN RAISE NOTICE 'already applied'; RETURN; END IF;

  -- The five marketing event CTEs are the only places this window appears.
  v_n := (length(v_def) - length(replace(v_def, 'v_live_from AND v_week_end', ''))) / length('v_live_from AND v_week_end');
  IF v_n <> 5 THEN
    RAISE EXCEPTION 'expected 5 marketing event windows, found % - another thread changed rp_week_scoreboard_for', v_n;
  END IF;
  IF position(v_agg_old IN v_def) = 0 OR position(v_rep_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'marketing aggregate block not in the expected shape';
  END IF;

  v_def := replace(v_def, 'v_live_from AND v_week_end', 'v_cycle_start AND v_week_end');
  v_def := replace(v_def, v_agg_old, v_agg_new);
  v_def := replace(v_def, v_rep_old, v_rep_new);
  EXECUTE v_def;
END $mig$;
