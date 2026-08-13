-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-08 03:47:44 UTC (ledger name: inject_marketing_bonus_into_cpr_html_dynamic) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260708034744.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Dynamically patch compose_weekly_cpr_html to inject marketing bonus render just before prize cart
-- Avoids reproducing the ~350-line function verbatim in this migration file
DO $patch$
DECLARE
  v_src         TEXT;
  v_needle      TEXT;
  v_replacement TEXT;
  v_new_src     TEXT;
  v_new_def     TEXT;
BEGIN
  SELECT prosrc INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname='public' AND p.proname='compose_weekly_cpr_html'
  LIMIT 1;

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'compose_weekly_cpr_html not found';
  END IF;

  v_needle      := 'v_html := v_html || public.render_cpr_prize_cart_html(p_agency_id, p_week_ending_date);';
  v_replacement := 'v_html := v_html || public.render_cpr_marketing_bonus_html(p_agency_id, p_week_ending_date);'
                   || E'\n\n  '
                   || 'v_html := v_html || public.render_cpr_prize_cart_html(p_agency_id, p_week_ending_date);';

  IF position(v_needle IN v_src) = 0 THEN
    -- Idempotent: if the marketing render call is already there, do nothing
    IF position('render_cpr_marketing_bonus_html' IN v_src) > 0 THEN
      RAISE NOTICE 'Marketing bonus render already injected; skipping';
      RETURN;
    END IF;
    RAISE EXCEPTION 'Injection anchor not found in compose_weekly_cpr_html';
  END IF;

  v_new_src := replace(v_src, v_needle, v_replacement);

  v_new_def := 'CREATE OR REPLACE FUNCTION public.compose_weekly_cpr_html(p_agency_id uuid, p_week_ending_date date)
     RETURNS text
     LANGUAGE plpgsql
     SECURITY DEFINER
     SET search_path TO ''public''
    AS $body$' || v_new_src || '$body$;';

  EXECUTE v_new_def;
  RAISE NOTICE 'Injected marketing bonus render into compose_weekly_cpr_html';
END;
$patch$;
