-- render_team_stats_block already asked the resolver for the open week, but for a
-- CLOSED week it printed weekly_cpr_team_detail.sales_points straight off the row.
-- For a closed week the resolver returns the frozen paid figure, which is the number
-- the team was actually paid on. Point the closed-week line at it so both branches
-- show the same source. Read, guard, patch the one line, execute.
DO $migrate$
DECLARE
  v_def text;
  v_old text := '|| to_char(floor(COALESCE(v_row.cpr_sales, 0)), ''FM999G999G999'') || ''/''';
  v_new text := '|| to_char(floor(COALESCE(v_row.sp_qtd, 0)), ''FM999G999G999'') || ''/''';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'render_team_stats_block';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'render_team_stats_block not found';
  END IF;
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'expected closed-week sales line not found - another thread changed this function, re-read before patching';
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'expected exactly one closed-week sales line, found more';
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
END
$migrate$;
