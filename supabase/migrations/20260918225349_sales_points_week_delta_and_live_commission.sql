-- Peter 2026-09-18: the Payroll section shows no commissions.
--
-- Cause: weekly commission for the CURRENT week is this week's quarter-to-date
-- sales points minus last week's, and both halves were read straight off the
-- stored weekly_cpr_team_detail.sales_points column. That column is blank until
-- the week is filled in or frozen, so the subtraction was 0 - 2,745.99, clamped
-- to zero. Every teammate showed $0 commission.
--
-- One helper now answers "what did this person write this week", built on
-- get_sales_points_qtd, the single resolver. Used everywhere the residual pool
-- needed the current week's number.

CREATE OR REPLACE FUNCTION public.sales_points_week_delta(p_agency_id uuid, p_week_end date)
RETURNS TABLE(team_member_id uuid, qtd numeric, prior_qtd numeric, week_delta numeric)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_cycle_start date;
  v_week_end    date;
  v_prior       date;
BEGIN
  SELECT c.week_ending_saturday, c.cycle_start
    INTO v_week_end, v_cycle_start
  FROM public.current_cycle_info(p_agency_id, p_week_end) c;

  -- Sales points are quarter-to-date, so the first week of a cycle has no prior
  -- week to subtract. Subtracting last quarter's closing total would wipe the
  -- whole week out.
  v_prior := v_week_end - 7;
  IF v_prior < v_cycle_start THEN v_prior := NULL; END IF;

  RETURN QUERY
  WITH now_q AS (
    SELECT g.team_id AS tm, g.sales_points AS pts
    FROM public.get_sales_points_qtd(p_agency_id, v_week_end) g
  ),
  prev_q AS (
    SELECT g.team_id AS tm, g.sales_points AS pts
    FROM (SELECT v_prior AS d WHERE v_prior IS NOT NULL) x
    CROSS JOIN LATERAL public.get_sales_points_qtd(p_agency_id, x.d) g
  )
  SELECT n.tm,
         ROUND(n.pts, 2),
         ROUND(COALESCE(p.pts, 0), 2),
         ROUND(GREATEST(0, n.pts - COALESCE(p.pts, 0)), 2)
  FROM now_q n
  LEFT JOIN prev_q p ON p.tm = n.tm;
END
$function$;

DO $mig$
DECLARE
  v_def text;
  s1 text := '(SELECT wctd.sales_points FROM public.weekly_cpr_team_detail wctd JOIN public.weekly_cpr_reports wr ON wr.id = wctd.weekly_cpr_report_id WHERE wr.agency_id = p_agency_id AND wctd.team_member_id = r.id AND wr.week_ending_date = cw.week_end_date LIMIT 1)';
  n1 text := '(SELECT swd.qtd FROM public.sales_points_week_delta(p_agency_id, p_week_end_date) swd WHERE swd.team_member_id = r.id LIMIT 1)';
  s2 text := '(SELECT wctd.sales_points FROM public.weekly_cpr_team_detail wctd JOIN public.weekly_cpr_reports wr ON wr.id = wctd.weekly_cpr_report_id WHERE wr.agency_id = p_agency_id AND wctd.team_member_id = r.id AND wr.week_ending_date < cw.week_end_date AND wr.week_ending_date >= v_cycle_start ORDER BY wr.week_ending_date DESC LIMIT 1)';
  n2 text := '(SELECT swd.prior_qtd FROM public.sales_points_week_delta(p_agency_id, p_week_end_date) swd WHERE swd.team_member_id = r.id LIMIT 1)';
  s3 text := 'MAX(CASE WHEN wr.week_ending_date = p_week_end_date THEN wctd.sales_points END)';
  n3 text := '(SELECT swd.qtd FROM public.sales_points_week_delta(p_agency_id, p_week_end_date) swd WHERE swd.team_member_id = r.id LIMIT 1)';
  s4 text := 'MAX(CASE WHEN wr.week_ending_date < p_week_end_date THEN wctd.sales_points END)';
  n4 text := '(SELECT swd.prior_qtd FROM public.sales_points_week_delta(p_agency_id, p_week_end_date) swd WHERE swd.team_member_id = r.id LIMIT 1)';
  s5 text := 'WHEN ws.week_ending >= v_cycle_start THEN COALESCE((SELECT wctd.commission FROM public.weekly_cpr_reports wr JOIN public.weekly_cpr_team_detail wctd ON wctd.weekly_cpr_report_id = wr.id WHERE wr.agency_id = p_agency_id AND wr.week_ending_date = ws.week_ending AND wctd.team_member_id = r.id LIMIT 1), 0)';
  n5 text := 'WHEN ws.week_ending = p_week_end_date THEN COALESCE((SELECT swd.week_delta FROM public.sales_points_week_delta(p_agency_id, p_week_end_date) swd WHERE swd.team_member_id = r.id LIMIT 1), 0) WHEN ws.week_ending >= v_cycle_start THEN COALESCE((SELECT wctd.commission FROM public.weekly_cpr_reports wr JOIN public.weekly_cpr_team_detail wctd ON wctd.weekly_cpr_report_id = wr.id WHERE wr.agency_id = p_agency_id AND wr.week_ending_date = ws.week_ending AND wctd.team_member_id = r.id LIMIT 1), 0)';
  fn text;
  hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'compute_weekly_comp_residual_pool';
  IF v_def IS NULL THEN RAISE EXCEPTION 'compute_weekly_comp_residual_pool not found'; END IF;

  FOREACH fn IN ARRAY ARRAY[s1, s2, s4, s5] LOOP
    hits := (length(v_def) - length(replace(v_def, fn, ''))) / length(fn);
    IF hits <> 1 THEN RAISE EXCEPTION 'expected exactly 1 hit, found % for anchor starting %', hits, left(fn, 60); END IF;
  END LOOP;
  hits := (length(v_def) - length(replace(v_def, s3, ''))) / length(s3);
  IF hits <> 2 THEN RAISE EXCEPTION 'expected exactly 2 hits for the current-week QTD anchor, found %', hits; END IF;

  v_def := replace(v_def, s1, n1);
  v_def := replace(v_def, s2, n2);
  v_def := replace(v_def, s3, n3);
  v_def := replace(v_def, s4, n4);
  v_def := replace(v_def, s5, n5);

  EXECUTE v_def;
END
$mig$;
