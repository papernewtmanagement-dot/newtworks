-- Peter 2026-09-11: someone whose last day was BEFORE this CPR week started should not
-- appear in the Requirements list at all. They stay inside the week loop so their historical
-- debt and the team allocation math for weeks they DID work are untouched; they are only
-- dropped from the returned rows. Mid-week terminations (end_date inside the week) are
-- unchanged and still return with zeros, per the 2026-09-02 ruling.
DO $mig$
DECLARE
  v_def text;
  v_old text := E'  FROM jsonb_each(v_state);\nEND;';
  v_new text := E'  FROM jsonb_each(v_state) s\n'
             || E'  JOIN public.team t ON t.id = (s.key)::uuid\n'
             || E'  WHERE t.end_date IS NULL OR t.end_date >= (p_week_ending_date - 6);\nEND;';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_weekly_cpr_requirements';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'get_weekly_cpr_requirements not found';
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'anchor not found in get_weekly_cpr_requirements';
  END IF;

  v_def := replace(v_def, v_old, v_new);
  EXECUTE v_def;
END
$mig$;