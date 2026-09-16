-- Adds the three tier step sizes to the tiers block so a caller can say
-- "one step per 6 cars" without hardcoding 6. Constants already live here and
-- nowhere else; this only publishes them. Every existing key is unchanged.
DO $mig$
DECLARE
  v_def text;
  v_old text := E'      ''auto_rep_cap'',         c_auto_rep_cap,\n';
  v_new text := E'      ''auto_app_step'',        c_auto_app_step,\n'
             || E'      ''fire_app_step'',        c_fire_app_step,\n'
             || E'      ''life_dollar_step'',     c_pc_life_dollar_step,\n'
             || E'      ''auto_rep_cap'',         c_auto_rep_cap,\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'compute_sp_from_production';

  IF position(E'''auto_app_step''' IN v_def) > 0 THEN RAISE NOTICE 'already applied'; RETURN; END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'tiers block not in the expected shape - another thread changed compute_sp_from_production';
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
END $mig$;
