-- Consolidate 13 identical updated_at touch functions into public.set_updated_at().
--
-- Every one of these did:
--   BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
--
-- Consolidation: kept public.set_updated_at() as canonical, re-pointed all
-- triggers hanging off the 12 duplicates, then dropped the duplicates.
--
-- Verified 2026-07-08 before shipping:
--   * All trigger defs match `BEFORE UPDATE ... EXECUTE FUNCTION <fn>()` shape
--   * No pl/pgsql function outside the touch fns themselves references them
--   * set_handbook_updated_at had no live trigger (handbook table dropped
--     earlier today during manuals consolidation) -- dropped function only.
--
-- Result: 159 -> 147 total functions; 26 triggers re-pointed to canonical.

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
BEGIN
  FOR r IN
    SELECT t.tgname, c.relname AS table_name, n.nspname AS schema_name, p.proname AS old_fn_name
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
  END LOOP;

  FOREACH old_fn IN ARRAY old_fns LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS public.%I()', old_fn);
  END LOOP;

  DROP FUNCTION IF EXISTS public.set_handbook_updated_at();
END $$;
