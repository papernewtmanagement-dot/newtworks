-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-18 05:30:27 UTC (ledger name: 1pct_gain_add_last_wk_to_per_person) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260718053027.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
DO $migration$
DECLARE
  v_src text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_src FROM pg_proc WHERE proname='write_weekly_comp_v2';

  v_src := replace(v_src,
    $$COALESCE(a.avg_new_sp, 0)::numeric AS avg_prior_13wk, COALESCE(a.q_total, 0)::numeric AS ref_quarter_total,$$,
    $$COALESCE(a.avg_new_sp, 0)::numeric AS avg_prior_13wk, COALESCE(a.q_total, 0)::numeric AS ref_quarter_total, COALESCE(a.last_wk_new_sp, 0)::numeric AS last_wk_new_sp,$$);

  EXECUTE v_src;
END
$migration$;

SELECT (public.write_weekly_comp_v2('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-07-18'::date))->'goals_bonus_detail' AS goals;
