-- The first week the production module captured everything live (Sun 9/13 - Sat 9/19/2026).
-- Weeks before it only exist as reported totals. Payroll locking a week never changes which kind of week it is.
CREATE OR REPLACE FUNCTION public.rp_live_capture_from(p_agency_id uuid)
 RETURNS date LANGUAGE sql IMMUTABLE AS $$ SELECT DATE '2026-09-19' $$;

DO $mig$
DECLARE d text; n text; r text[][] := ARRAY[
  ARRAY['IF v_week_end <= c_reported_through THEN',
        'IF v_week_end <= c_reported_through AND v_week_end < public.rp_live_capture_from(p_agency_id) THEN'],
  ARRAY['COALESCE(g.growth, 0) AS week_growth,',
        'COALESCE(g.growth, 0) AS week_growth, g.qtd AS week_qtd,'],
  ARRAY['''qtd_points'', COALESCE((s.cur->''commission''->>''total_commission'')::numeric, 0),',
        '''qtd_points'', COALESCE(s.week_qtd, (s.cur->''commission''->>''total_commission'')::numeric, 0),'],
  ARRAY['jsonb_build_object(''points'', COALESCE(m.points, 0), ''qtd_points'', COALESCE(mq.qtd, 0),',
        'jsonb_build_object(''points'', CASE WHEN v_week_end <= c_reported_through THEN COALESCE(mw.points, 0) ELSE COALESCE(m.points, 0) END, ''qtd_points'', COALESCE(mq.qtd, 0),'],
  ARRAY['  -- One pricing pass, two totals: this week, and the quarter so far.',
        '  -- A locked week pays what was frozen on lock, so its weekly marketing number reads that.
  m_week_frozen AS (
    SELECT m.team_member_id AS tm, SUM(m.points) AS points
    FROM public.marketing_points m
    WHERE m.agency_id = p_agency_id AND m.week_end_date = v_week_end
    GROUP BY m.team_member_id
  ),
  -- One pricing pass, two totals: this week, and the quarter so far.'],
  ARRAY['LEFT JOIN m_reported mr ON mr.tm = r.id',
        'LEFT JOIN m_reported mr ON mr.tm = r.id
    LEFT JOIN m_week_frozen mw ON mw.tm = r.id']
]; i int;
BEGIN
  d := pg_get_functiondef('public.rp_week_scoreboard_for(uuid,date)'::regprocedure);
  FOR i IN 1..array_length(r,1) LOOP
    IF (length(d) - length(replace(d, r[i][1], ''))) / length(r[i][1]) <> 1 THEN
      RAISE EXCEPTION 'patch % did not match exactly once', i;
    END IF;
    d := replace(d, r[i][1], r[i][2]);
  END LOOP;
  EXECUTE d;
END $mig$;
