-- Peter 2026-08-31: "None of this is in effect until I say it is."
--
-- The previous migration hardcoded a go-live of 2026-09-05, which would have flipped the
-- retention third onto Retention Points automatically this week with nobody throwing a
-- switch. Wrong. Go-live is now a setting Peter sets, and it is EMPTY, so every week keeps
-- paying the retention third by weighted hours exactly as before.
--
-- To turn it on later, set the first week-ending Saturday it should apply from:
--   UPDATE public.settings SET setting_value = '2026-09-12'
--    WHERE agency_id = '...' AND setting_key = 'retention_points_go_live_week_end';
-- Empty or missing = not in effect.

INSERT INTO public.settings (agency_id, setting_key, setting_value, setting_type, description, updated_at)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'retention_points_go_live_week_end', '', 'text',
        'First week-ending Saturday the retention third pays on Retention Points instead of weighted hours. Empty = not in effect; weighted hours stay in force. Peter sets this when he says the program is live.', now())
ON CONFLICT DO NOTHING;

DO $mig$
DECLARE
  v_def text; n int;
  a_decl CONSTANT text := $x$  v_rp_go_live CONSTANT date := DATE '2026-09-05';$x$;
  a_set  CONSTANT text := $x$  v_points_mode := (p_week_end_date >= v_rp_go_live);$x$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p JOIN pg_namespace nsp ON nsp.oid=p.pronamespace
  WHERE nsp.nspname='public' AND p.proname='compute_weekly_comp_residual_pool';
  IF v_def IS NULL THEN RAISE EXCEPTION 'function not found'; END IF;

  n := (position(a_decl in v_def) > 0)::int;
  IF n <> 1 THEN RAISE EXCEPTION 'go-live declaration anchor not found'; END IF;
  n := (length(v_def) - length(replace(v_def, a_set, ''))) / length(a_set);
  IF n <> 1 THEN RAISE EXCEPTION 'points-mode anchor matched % times', n; END IF;

  -- swap the hardcoded constant for a settings lookup
  v_def := replace(v_def, a_decl, $r$  v_rp_go_live date;$r$);
  v_def := replace(v_def, a_set,
    $r$  SELECT NULLIF(btrim(s.setting_value), '')::date INTO v_rp_go_live
    FROM public.settings s
    WHERE s.agency_id = p_agency_id AND s.setting_key = 'retention_points_go_live_week_end';
  v_points_mode := (v_rp_go_live IS NOT NULL AND p_week_end_date >= v_rp_go_live);$r$);

  EXECUTE v_def;
  EXECUTE 'REVOKE ALL ON FUNCTION public.compute_weekly_comp_residual_pool(uuid, date) FROM PUBLIC';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.compute_weekly_comp_residual_pool(uuid, date) TO authenticated, service_role';
END $mig$;
