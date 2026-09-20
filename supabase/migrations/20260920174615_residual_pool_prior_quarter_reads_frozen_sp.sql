-- Same class as the comp-writer fix. compute_weekly_comp_residual_pool's
-- last_completed_q_per_person CTE finds a person's prior-quarter sales-points total by looking
-- for the newest week where weekly_cpr_team_detail.sales_points is not null. Nothing writes that
-- column any more, so from Q4 2026 onward it would find nothing and every rolling 13-week average
-- would fall to zero. sales_points_frozen is the canonical stamped value
-- (freeze_sales_points_for_week writes it from get_sales_points_qtd on send), so read that first
-- and keep the old column as the fallback for the backfilled history. No behaviour change today.
DO $do$
DECLARE
  v_def text;
  v_before text;
  v_after  text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'compute_weekly_comp_residual_pool';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'compute_weekly_comp_residual_pool not found';
  END IF;

  v_before := 'last_completed_q_per_person AS (SELECT DISTINCT ON (d.team_member_id) d.team_member_id, d.sales_points AS q_total, r.week_ending_date AS q_end_sat FROM public.weekly_cpr_team_detail d JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id WHERE r.agency_id = p_agency_id AND d.sales_points IS NOT NULL AND';
  v_after  := 'last_completed_q_per_person AS (SELECT DISTINCT ON (d.team_member_id) d.team_member_id, COALESCE(d.sales_points_frozen, d.sales_points) AS q_total, r.week_ending_date AS q_end_sat FROM public.weekly_cpr_team_detail d JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id WHERE r.agency_id = p_agency_id AND COALESCE(d.sales_points_frozen, d.sales_points) IS NOT NULL AND';

  IF position(v_before in v_def) = 0 THEN
    RAISE EXCEPTION 'last_completed_q_per_person CTE did not match; aborting rather than guessing';
  END IF;

  v_def := replace(v_def, v_before, v_after);
  EXECUTE v_def;
END $do$;
