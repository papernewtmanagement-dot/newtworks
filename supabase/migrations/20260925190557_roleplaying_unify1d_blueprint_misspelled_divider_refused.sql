-- Roleplaying unification, step 1 follow-up: a blueprint entry like {"ST": {"divider": 5}} (wrong key) was accepted and
-- would have rolled with the standard divider in silence. The check compared a missing key's type with 'number', which
-- is neither true nor false, so the refusal never fired. Now a missing key counts as wrong.
DO $m$
DECLARE
  v_def text;
  v_old text := $a$jsonb_typeof(v_val -> 'divisor') <> 'number'$a$;
  v_new text := $a$jsonb_typeof(v_val -> 'divisor') IS DISTINCT FROM 'number'$a$;
BEGIN
  v_def := pg_get_functiondef('public.rpg_creatures_template_check()'::regprocedure);
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'rpg_creatures_template_check: the divider type check is not there exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $m$;

DO $g$
DECLARE v_ok boolean := false;
BEGIN
  BEGIN
    INSERT INTO public.rpg_creatures (key, name, size, creature_type, color, shown_to_players, sort_order, blueprint)
    VALUES ('zz_guard', 'ZZ Guard', 'Medium', 'beast', '#737A59', false, 999, '{"ST": {"divider": 5}}');
  EXCEPTION WHEN OTHERS THEN
    v_ok := SQLERRM LIKE '%must be a set number or {"divisor": n}%';
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'a misspelled divider key is still accepted'; END IF;
END $g$;

NOTIFY pgrst, 'reload schema';
