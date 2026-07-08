-- Dynamically patch compose_weekly_cpr_html to inject marketing bonus render just before prize cart
-- Idempotent via existence check
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

  IF position('render_cpr_marketing_bonus_html' IN v_src) > 0 THEN
    RAISE NOTICE 'Marketing bonus render already injected; skipping';
    RETURN;
  END IF;

  v_needle      := 'v_html := v_html || public.render_cpr_prize_cart_html(p_agency_id, p_week_ending_date);';
  v_replacement := 'v_html := v_html || public.render_cpr_marketing_bonus_html(p_agency_id, p_week_ending_date);' || E'

  ' || 'v_html := v_html || public.render_cpr_prize_cart_html(p_agency_id, p_week_ending_date);';

  IF position(v_needle IN v_src) = 0 THEN
    RAISE EXCEPTION 'Injection anchor not found in compose_weekly_cpr_html';
  END IF;

  v_new_src := replace(v_src, v_needle, v_replacement);

  v_new_def := 'CREATE OR REPLACE FUNCTION public.compose_weekly_cpr_html(p_agency_id uuid, p_week_ending_date date)
     RETURNS text
     LANGUAGE plpgsql
     SECURITY DEFINER
     SET search_path TO 'public'
    AS $body$' || v_new_src || '$body$;';

  EXECUTE v_new_def;
  RAISE NOTICE 'Injected marketing bonus render into compose_weekly_cpr_html';
END;
$patch$;
