-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-18 05:45:54 UTC (ledger name: revert_role_w_to_7_11_model) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260718054554.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
DO $migration$
DECLARE
  v_src text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_src FROM pg_proc WHERE proname='compute_weekly_comp_residual_pool';

  v_src := replace(v_src,
    $$1.00 AS role_w$$,
    $$CASE WHEN r.r_role_category = 'Retention' THEN 1.00 WHEN r.r_role_category = 'Sales' THEN 0.25 ELSE 0 END AS role_w$$);

  EXECUTE v_src;
END
$migration$;

SELECT public.write_weekly_comp_v2('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-07-18'::date);
