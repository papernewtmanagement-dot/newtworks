-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-18 05:29:05 UTC (ledger name: pool_splits_by_role_category_and_1pct_interim) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260718052905.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Read current fn source, apply 3 surgical patches, install.
DO $migration$
DECLARE
  v_src text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_src FROM pg_proc WHERE proname='compute_weekly_comp_residual_pool';

  -- Patch 1: role_w keyed off role_category (not role text which got renamed to 'Inside Sales'/'Acquisition')
  v_src := replace(v_src,
    $$CASE WHEN r.r_role = 'Reception' THEN 1.00 WHEN r.r_role IN ('Outbound', 'Inbound') THEN 0.25 ELSE 0 END AS role_w$$,
    $$CASE WHEN r.r_role_category = 'Retention' THEN 1.00 WHEN r.r_role_category = 'Sales' THEN 0.25 ELSE 0 END AS role_w$$);

  -- Patch 2: gate sp13/sp4 share by role_category='Sales' → Cassie/Stephanie out of sales split
  v_src := replace(v_src,
    $$CASE WHEN ps.team_avg_13wk > 0 THEN c.c_avg_13wk / ps.team_avg_13wk ELSE 0 END AS sp13_share_ratio, CASE WHEN ps.team_avg_4wk > 0 THEN c.c_avg_4wk / ps.team_avg_4wk ELSE 0 END AS sp4_share_ratio$$,
    $$CASE WHEN c.r_role_category = 'Sales' AND ps.team_avg_13wk_sales > 0 THEN c.c_avg_13wk / ps.team_avg_13wk_sales ELSE 0 END AS sp13_share_ratio, CASE WHEN c.r_role_category = 'Sales' AND ps.team_avg_4wk_sales > 0 THEN c.c_avg_4wk / ps.team_avg_4wk_sales ELSE 0 END AS sp4_share_ratio$$);

  -- Patch 3: add team_avg_13wk_sales + team_avg_4wk_sales to team_totals (Sales-only denominators)
  v_src := replace(v_src,
    $$SUM(c.c_avg_13wk) AS team_avg_13wk, SUM(c.c_avg_4wk) AS team_avg_4wk,$$,
    $$SUM(c.c_avg_13wk) AS team_avg_13wk, SUM(c.c_avg_4wk) AS team_avg_4wk, SUM(CASE WHEN c.r_role_category = 'Sales' THEN c.c_avg_13wk ELSE 0 END) AS team_avg_13wk_sales, SUM(CASE WHEN c.r_role_category = 'Sales' THEN c.c_avg_4wk ELSE 0 END) AS team_avg_4wk_sales,$$);

  EXECUTE v_src;
END
$migration$;
