-- An unset rpg.engine / rpg.move flag reads as NULL, and NULL = 'on' is NULL, not false, so "NOT (parent OR flag)"
-- was NULL for the kids' login and the guards never fired. Each flag test now reads a missing flag as ''.
DO $patch$
DECLARE
  f text[] := ARRAY['public.rpg_act', 'public.rpg_can_see_character', 'public.rpg_session_adjust_vitality'];
  n integer[] := ARRAY[1, 2, 2];
  i integer; c integer; d text;
BEGIN
  FOR i IN 1..3 LOOP
    d := pg_get_functiondef(f[i]::regproc);
    d := regexp_replace(d, 'current_setting\(''rpg\.(engine|move)'', true\) = ''on''', 'coalesce(current_setting(''rpg.\1'', true), '''') = ''on''', 'g');
    c := (length(d) - length(replace(d, 'coalesce(current_setting(''rpg.', ''))) / length('coalesce(current_setting(''rpg.');
    IF c <> n[i] THEN RAISE EXCEPTION '% flag tests found % times, expected %', f[i], c, n[i]; END IF;
    EXECUTE d;
  END LOOP;
END
$patch$;

