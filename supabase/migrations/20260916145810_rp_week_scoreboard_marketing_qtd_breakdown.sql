-- The marketing summary showed only this week's build-up, so the quarter-to-date
-- number had nothing behind it. Adds a per-event rollup for the whole quarter
-- (qtd_mix) and the lump that was reported before the capture module went live
-- (qtd_reported), which together account for every point in qtd_points.
-- Peter 2026-09-16. Read off the same pricing pass; no new maths.
DO $mig$
DECLARE
  v_def text;
  v_qtd_old text := E'  m_qtd AS (\n    SELECT COALESCE(a.tm, rp.tm) AS tm,\n           COALESCE(a.qtd_live, 0) + COALESCE(rp.points, 0) AS qtd\n    FROM m_agg a FULL JOIN m_reported rp ON rp.tm = a.tm\n  ),\n';
  v_qtd_new text := E'  m_qtd AS (\n    SELECT COALESCE(a.tm, rp.tm) AS tm,\n           COALESCE(a.qtd_live, 0) + COALESCE(rp.points, 0) AS qtd\n    FROM m_agg a FULL JOIN m_reported rp ON rp.tm = a.tm\n  ),\n'
                 || E'  -- Quarter-to-date build-up: one row per kind of event, over the whole cycle.\n'
                 || E'  m_mix AS (\n'
                 || E'    SELECT z.tm, jsonb_agg(jsonb_build_object(''kind'', z.event_key, ''label'', z.label, ''n'', z.n, ''points'', z.pts)\n'
                 || E'                          ORDER BY z.pts DESC, z.label) AS mix\n'
                 || E'    FROM (SELECT tm, event_key, label, count(*)::int AS n, ROUND(SUM(points), 2) AS pts\n'
                 || E'          FROM m_priced GROUP BY tm, event_key, label) z\n'
                 || E'    GROUP BY z.tm\n'
                 || E'  ),\n';
  v_obj_old text := E'      jsonb_build_object(''points'', COALESCE(m.points, 0), ''qtd_points'', COALESCE(mq.qtd, 0), ''items'', COALESCE(m.items, ''[]''::jsonb)) AS marketing,\n';
  v_obj_new text := E'      jsonb_build_object(''points'', COALESCE(m.points, 0), ''qtd_points'', COALESCE(mq.qtd, 0),\n'
                 || E'        ''qtd_mix'', COALESCE(mx.mix, ''[]''::jsonb), ''qtd_reported'', COALESCE(mr.points, 0),\n'
                 || E'        ''items'', COALESCE(m.items, ''[]''::jsonb)) AS marketing,\n';
  v_join_old text := E'    LEFT JOIN m_qtd mq ON mq.tm = r.id\n';
  v_join_new text := E'    LEFT JOIN m_qtd mq ON mq.tm = r.id\n    LEFT JOIN m_mix mx ON mx.tm = r.id\n    LEFT JOIN m_reported mr ON mr.tm = r.id\n';
  v_rep_old text := E'        jsonb_build_object(''points'', COALESCE(m.points, 0), ''qtd_points'', COALESCE(m.qtd, 0), ''items'', ''[]''::jsonb) AS marketing,\n';
  v_rep_new text := E'        jsonb_build_object(''points'', COALESCE(m.points, 0), ''qtd_points'', COALESCE(m.qtd, 0),\n'
                 || E'          ''qtd_mix'', NULL::jsonb, ''qtd_reported'', NULL::numeric, ''items'', ''[]''::jsonb) AS marketing,\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rp_week_scoreboard_for';

  IF position('m_mix AS (' IN v_def) > 0 THEN RAISE NOTICE 'already applied'; RETURN; END IF;
  IF position(v_qtd_old IN v_def) = 0 OR position(v_obj_old IN v_def) = 0
     OR position(v_join_old IN v_def) = 0 OR position(v_rep_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'marketing block not in the expected shape - another thread changed rp_week_scoreboard_for';
  END IF;

  v_def := replace(v_def, v_qtd_old,  v_qtd_new);
  v_def := replace(v_def, v_obj_old,  v_obj_new);
  v_def := replace(v_def, v_join_old, v_join_new);
  v_def := replace(v_def, v_rep_old,  v_rep_new);
  EXECUTE v_def;
END $mig$;
