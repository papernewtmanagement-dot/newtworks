-- get_sales_points_qtd is the one resolver for a person's quarter-to-date sales
-- points (frozen > live production > CPR override > self-reported). It reads
-- weekly_cpr_team_detail, which is admin-or-own-row at the ROW level, so an
-- invoker-rights version handed a non-admin viewer only their own row and
-- silently returned 0 for everyone else. Sales points are already shown
-- team-wide on the scoreboard, so nothing new is exposed here. Same treatment
-- compute_scorecard_done_for_cpr_week got for the same reason (20260831134254).
DO $mig$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_sales_points_qtd';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'get_sales_points_qtd not found';
  END IF;

  IF position(' STABLE' IN v_def) = 0 THEN
    RAISE EXCEPTION 'expected a STABLE marker to attach SECURITY DEFINER to';
  END IF;

  EXECUTE replace(v_def, E' STABLE\n', E' STABLE SECURITY DEFINER\n SET search_path TO ''public'', ''pg_temp''\n');
END
$mig$;
