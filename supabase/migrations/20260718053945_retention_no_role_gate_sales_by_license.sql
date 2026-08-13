-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-18 05:39:45 UTC (ledger name: retention_no_role_gate_sales_by_license) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260718053945.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
DO $migration$
DECLARE
  v_src text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_src FROM pg_proc WHERE proname='compute_weekly_comp_residual_pool';

  -- Retention: role_w = 1.00 for everyone (no gate)
  v_src := replace(v_src,
    $$CASE WHEN r.r_role_category = 'Retention' THEN 1.00 WHEN r.r_role_category = 'Sales' THEN 0.25 ELSE 0 END AS role_w$$,
    $$1.00 AS role_w$$);

  -- Sales split: gate by P&C license (was role_category='Sales')
  v_src := replace(v_src,
    $$CASE WHEN c.r_role_category = 'Sales' AND ps.team_avg_13wk_sales > 0 THEN c.c_avg_13wk / ps.team_avg_13wk_sales ELSE 0 END AS sp13_share_ratio, CASE WHEN c.r_role_category = 'Sales' AND ps.team_avg_4wk_sales > 0 THEN c.c_avg_4wk / ps.team_avg_4wk_sales ELSE 0 END AS sp4_share_ratio$$,
    $$CASE WHEN c.license_pc AND ps.team_avg_13wk_licensed > 0 THEN c.c_avg_13wk / ps.team_avg_13wk_licensed ELSE 0 END AS sp13_share_ratio, CASE WHEN c.license_pc AND ps.team_avg_4wk_licensed > 0 THEN c.c_avg_4wk / ps.team_avg_4wk_licensed ELSE 0 END AS sp4_share_ratio$$);

  -- team_totals: replace _sales suffix with _licensed, gate on license_pc
  v_src := replace(v_src,
    $$SUM(CASE WHEN c.r_role_category = 'Sales' THEN c.c_avg_13wk ELSE 0 END) AS team_avg_13wk_sales, SUM(CASE WHEN c.r_role_category = 'Sales' THEN c.c_avg_4wk ELSE 0 END) AS team_avg_4wk_sales,$$,
    $$SUM(CASE WHEN c.license_pc THEN c.c_avg_13wk ELSE 0 END) AS team_avg_13wk_licensed, SUM(CASE WHEN c.license_pc THEN c.c_avg_4wk ELSE 0 END) AS team_avg_4wk_licensed,$$);

  -- combined CTE: expose license_pc so the distributed CTE can gate on it
  v_src := replace(v_src,
    $$COALESCE(wf.weighted_hours, 0) AS c_weighted_hours, wf.role_w, wf.location_w, wf.tenure_w, wf.license_w$$,
    $$COALESCE(wf.weighted_hours, 0) AS c_weighted_hours, wf.role_w, wf.location_w, wf.tenure_w, wf.license_w, r.license_pc$$);

  EXECUTE v_src;
END
$migration$;

SELECT public.write_weekly_comp_v2('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-07-18'::date);
