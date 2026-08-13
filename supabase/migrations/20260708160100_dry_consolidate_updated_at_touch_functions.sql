-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-08 16:01:00 UTC (ledger name: dry_consolidate_updated_at_touch_functions) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260708160100.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Consolidate 13 identical updated_at touch functions into public.set_updated_at().
--
-- Every one of these does:
--   BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
--
-- Consolidation: keep public.set_updated_at() as canonical, re-point all
-- triggers hanging off the 12 duplicates, then drop the duplicates.
--
-- Verified 2026-07-08 before shipping:
--   * All trigger defs match `BEFORE UPDATE ... EXECUTE FUNCTION <fn>()` shape
--   * No pl/pgsql function outside the touch fns themselves references them
--   * set_handbook_updated_at has no live trigger (handbook table dropped
--     earlier today during manuals consolidation) — drop function only.

DO $$
DECLARE
  r RECORD;
  old_fns TEXT[] := ARRAY[
    'bot_prompts_touch_updated_at',
    'fit_scorecards_touch_updated_at',
    'set_team_weekly_wrapups_updated_at',
    'set_weekly_cpr_updated_at',
    'tcer_touch_updated_at',
    'tg_license_type_reference_updated_at',
    'tg_marketing_ideas_touch_updated_at',
    'time_clock_touch_updated_at',
    'touch_book_alpha_split_updated_at',
    'touch_personal_register_updated_at',
    'update_updated_at'
  ];
  old_fn TEXT;
  n_triggers INT := 0;
BEGIN
  -- Re-point every trigger hanging off any duplicate touch fn
  FOR r IN
    SELECT
      t.tgname,
      t.oid AS trg_oid,
      c.relname AS table_name,
      n.nspname AS schema_name,
      p.proname AS old_fn_name
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_proc p ON p.oid = t.tgfoid
    WHERE NOT t.tgisinternal
      AND p.proname = ANY(old_fns)
  LOOP
    EXECUTE format('DROP TRIGGER %I ON %I.%I', r.tgname, r.schema_name, r.table_name);
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()',
      r.tgname, r.schema_name, r.table_name
    );
    n_triggers := n_triggers + 1;
    RAISE NOTICE 'Repointed %.% trigger % (was %)', r.schema_name, r.table_name, r.tgname, r.old_fn_name;
  END LOOP;

  RAISE NOTICE 'Total triggers re-pointed: %', n_triggers;

  -- Drop the now-orphaned duplicate functions
  FOREACH old_fn IN ARRAY old_fns LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS public.%I()', old_fn);
    RAISE NOTICE 'Dropped function %', old_fn;
  END LOOP;

  -- set_handbook_updated_at has no trigger (handbook table dropped) — still drop the fn
  DROP FUNCTION IF EXISTS public.set_handbook_updated_at();
  RAISE NOTICE 'Dropped function set_handbook_updated_at (no trigger)';
END $$;
