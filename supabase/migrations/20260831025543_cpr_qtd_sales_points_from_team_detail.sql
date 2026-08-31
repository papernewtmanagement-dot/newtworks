-- Peter directive 2026-08-30: the CPR report row's quarter-to-date sales points must
-- total up from the weekly_cpr_team_detail rows, not from self-reported team check-ins.
-- Standing policy: compute totals on display from the underlying rows. The team detail
-- rows get corrected during the week; the check-in figures do not, so the two drift.

CREATE OR REPLACE FUNCTION public.get_cpr_detail_sales_points_qtd(
  p_agency_id uuid,
  p_cycle_start date,
  p_week_ending_date date
) RETURNS numeric
LANGUAGE sql
STABLE
AS $fn$
  SELECT COALESCE(SUM(latest_sp), 0)::numeric
  FROM (
    SELECT DISTINCT ON (d.team_member_id) d.sales_points AS latest_sp
    FROM public.weekly_cpr_team_detail d
    JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
    WHERE r.agency_id = p_agency_id
      AND r.week_ending_date >= p_cycle_start
      AND r.week_ending_date <= p_week_ending_date
      AND d.sales_points IS NOT NULL
    ORDER BY d.team_member_id, r.week_ending_date DESC
  ) per_member;
$fn$;

COMMENT ON FUNCTION public.get_cpr_detail_sales_points_qtd(uuid, date, date) IS
'Quarter-to-date team sales points totalled from weekly_cpr_team_detail rows (Peter directive 2026-08-30). Per teammate, takes their most recent non-null sales_points row at or before the target week within the quarter, so a blank week carries forward rather than dropping their total to zero. Replaces get_team_checkin_totals as the CPR quarter-to-date source: check-in figures are self-reported and are never corrected after the fact, while the detail rows are. get_team_checkin_totals is still correct for the check-in system itself and for the live weekly quotes pace in render_team_status_block - do not repoint those.';

DO $mig$
DECLARE
  r        record;
  v_src    text;
  v_new    text;
  v_hits   int;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('weekly_cpr_compute_outcome',   'v_sales_points_qtd := v_totals.total_sales_points;',  'v_sales_points_qtd := public.get_cpr_detail_sales_points_qtd(p_agency_id, v_cycle.cycle_start, v_week_end);'),
      ('recompute_cpr_outcome',        'v_qtd_sp := v_totals.total_sales_points;',            'v_qtd_sp := public.get_cpr_detail_sales_points_qtd(p_agency_id, v_cycle.cycle_start, p_week_end_date);'),
      ('weekly_cpr_upsert_in_progress','v_sales_points_qtd := v_totals.total_sales_points;',  'v_sales_points_qtd := public.get_cpr_detail_sales_points_qtd(p_agency_id, v_cycle.cycle_start, v_week_end);'),
      ('get_weekly_cpr_requirements',  'v_sp_qtd := v_totals2.total_sales_points;',           'v_sp_qtd := public.get_cpr_detail_sales_points_qtd(p_agency_id, v_cyc.cycle_start, p_week_ending_date);')
    ) AS t(fname, old_line, new_line)
  LOOP
    SELECT count(*) INTO v_hits
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = r.fname;
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'expected exactly 1 function named %, found %', r.fname, v_hits;
    END IF;

    SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = r.fname;

    v_hits := (length(v_src) - length(replace(v_src, r.old_line, ''))) / length(r.old_line);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'in %: expected exactly 1 occurrence of "%", found %', r.fname, r.old_line, v_hits;
    END IF;

    v_new := replace(v_src, r.old_line,
      '-- Peter directive 2026-08-30: quarter-to-date sales points total up from the team' || E'\n'
      || '  -- detail rows, not from self-reported check-ins. See get_cpr_detail_sales_points_qtd.' || E'\n'
      || '  ' || r.new_line);

    EXECUTE v_new;
    RAISE NOTICE 'repointed %', r.fname;
  END LOOP;
END
$mig$;
