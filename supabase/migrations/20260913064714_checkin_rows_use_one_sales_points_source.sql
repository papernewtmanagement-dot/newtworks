-- The per-person sales points on the check-in message now come from
-- get_sales_points_qtd, the one source: CPR override first, then self-reported.
-- The Production figure is no longer read for sales points anywhere.
-- Quotes still come from Production, which is the part going live Monday.
-- The pace emoji's sales input is this week's movement in the same one source.
DO $do$
DECLARE v_src text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'render_team_status_block';

  IF position('COALESCE((p->''sales''->>''qtd_points'')::numeric, 0)  AS sp_qtd,' in v_src) = 0 THEN
    RAISE EXCEPTION 'render_team_status_block anchor drifted - not patching';
  END IF;

  -- Drop the two production sales columns out of the board CTE.
  v_new := replace(v_src,
    '             COALESCE((p->''sales''->>''qtd_points'')::numeric, 0)  AS sp_qtd,' || E'\n' ||
    '             COALESCE((p->''sales''->>''points'')::numeric, 0)      AS sp_week,',
    '');

  -- Add the one-source lookup and derive the week movement from it.
  v_new := replace(v_new,
    '    cpr AS (',
    '    spq AS (' || E'\n' ||
    '      SELECT s.team_id, s.sales_points AS sp_qtd,' || E'\n' ||
    '             GREATEST(0, s.sales_points - COALESCE(pv.sales_points, 0)) AS sp_week' || E'\n' ||
    '      FROM public.get_sales_points_qtd(p_agency_id, v_display_cycle.week_ending_saturday) s' || E'\n' ||
    '      LEFT JOIN public.get_sales_points_qtd(p_agency_id, v_display_cycle.week_ending_saturday - 7) pv' || E'\n' ||
    '        ON pv.team_id = s.team_id' || E'\n' ||
    '    ),' || E'\n' ||
    '    cpr AS (');

  v_new := replace(v_new,
    '      b.team_id AS board_team_id, b.quotes, b.sp_qtd, b.sp_week, b.marketing, b.retention',
    '      b.team_id AS board_team_id, b.quotes, b.marketing, b.retention,' || E'\n' ||
    '      COALESCE(sq.sp_qtd, 0) AS sp_qtd, COALESCE(sq.sp_week, 0) AS sp_week');

  v_new := replace(v_new,
    '    LEFT JOIN board b ON b.team_id = e.team_id',
    '    LEFT JOIN board b ON b.team_id = e.team_id' || E'\n' ||
    '    LEFT JOIN spq sq ON sq.team_id = e.team_id');

  EXECUTE v_new;
END
$do$;
