-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-18 05:29:29 UTC (ledger name: 1pct_gain_interim_formula_prior_q_12_plus_last_week) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260718052929.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- 1% gain target = ((prior_Q_total / 13) × 12 + last_completed_week_new_sp) / 13 × 1.01
-- Approximates rolling 13-week new-SP avg using prior Q data + most recent week delta.
-- Surgical patch to prior_avg CTE + goals_detail jsonb output.

DO $migration$
DECLARE
  v_src text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_src FROM pg_proc WHERE proname='write_weekly_comp_v2';

  v_src := replace(v_src,
    $$prior_avg AS (SELECT team_member_id, (q_total / 13.0)::numeric AS avg_new_sp, q_end_sat, q_total FROM last_completed_q),$$,
    $$last_week_delta AS (
      SELECT c.team_member_id,
             GREATEST(0, c.this_wk_qtd - COALESCE(pw.prior_wk_qtd, 0))::numeric AS last_wk_new_sp,
             c.this_wk_end
      FROM (
        SELECT DISTINCT ON (d.team_member_id) d.team_member_id, d.sales_points AS this_wk_qtd, r.week_ending_date AS this_wk_end,
               date_trunc('quarter', r.week_ending_date::timestamp)::date AS this_wk_qstart
        FROM public.weekly_cpr_team_detail d JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
        WHERE r.agency_id = p_agency_id AND r.week_ending_date < p_week_end_date AND d.sales_points IS NOT NULL
        ORDER BY d.team_member_id, r.week_ending_date DESC
      ) c
      LEFT JOIN LATERAL (
        SELECT d2.sales_points AS prior_wk_qtd
        FROM public.weekly_cpr_team_detail d2 JOIN public.weekly_cpr_reports r2 ON r2.id = d2.weekly_cpr_report_id
        WHERE r2.agency_id = p_agency_id AND d2.team_member_id = c.team_member_id
          AND r2.week_ending_date < c.this_wk_end
          AND date_trunc('quarter', r2.week_ending_date::timestamp)::date = c.this_wk_qstart
          AND d2.sales_points IS NOT NULL
        ORDER BY r2.week_ending_date DESC LIMIT 1) pw ON true
    ),
    prior_avg AS (
      SELECT lcq.team_member_id,
             (((lcq.q_total / 13.0) * 12 + COALESCE(lwd.last_wk_new_sp, 0)) / 13.0)::numeric AS avg_new_sp,
             lcq.q_end_sat, lcq.q_total,
             COALESCE(lwd.last_wk_new_sp, 0) AS last_wk_new_sp
      FROM last_completed_q lcq
      LEFT JOIN last_week_delta lwd ON lwd.team_member_id = lcq.team_member_id
    ),$$);

  v_src := replace(v_src,
    $$'ref_quarter_total', ROUND(w.ref_quarter_total, 2), 'ref_quarter_end', w.ref_quarter_end,$$,
    $$'ref_quarter_total', ROUND(w.ref_quarter_total, 2), 'ref_quarter_end', w.ref_quarter_end, 'last_wk_new_sp', ROUND(COALESCE(w.last_wk_new_sp,0), 2),$$);

  v_src := replace(v_src,
    $$SELECT p.*, (10 * (p.as_hits$$,
    $$SELECT p.*, 0::numeric AS last_wk_new_sp_placeholder, (10 * (p.as_hits$$);

  -- Actually the last_wk_new_sp needs to bubble through per_person → with_dollars
  -- Simpler: add last_wk_new_sp to per_person SELECT.
  v_src := replace(v_src,
    $$SELECT p.*, 0::numeric AS last_wk_new_sp_placeholder, (10 * (p.as_hits$$,
    $$SELECT p.*, (10 * (p.as_hits$$);

  v_src := replace(v_src,
    $$COALESCE(a.q_total, 0)::numeric    AS ref_quarter_total,$$,
    $$COALESCE(a.q_total, 0)::numeric    AS ref_quarter_total, COALESCE(a.last_wk_new_sp, 0)::numeric AS last_wk_new_sp,$$);

  EXECUTE v_src;
END
$migration$;

SELECT public.write_weekly_comp_v2('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-07-18'::date);
