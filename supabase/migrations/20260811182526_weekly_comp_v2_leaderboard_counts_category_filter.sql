DO $mig$
DECLARE
  old_def text;
  new_def text;
  anchor text := 'WHERE agency_id = p_agency_id AND (record_week_ending = p_week_end_date';
  new_anchor text := 'WHERE agency_id = p_agency_id AND category IN (''quarter_sp'',''week_sp'',''week_quotes'',''four_week_sp'') AND (record_week_ending = p_week_end_date';
  cnt int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO old_def
    FROM pg_proc p WHERE p.proname='write_weekly_comp_v2' AND p.pronamespace='public'::regnamespace;

  IF old_def IS NULL THEN
    RAISE EXCEPTION 'write_weekly_comp_v2 not found';
  END IF;

  cnt := (length(old_def) - length(replace(old_def, anchor, ''))) / length(anchor);
  IF cnt <> 1 THEN
    RAISE EXCEPTION 'anchor count is %, expected exactly 1 — STOP, concurrent session changed the function', cnt;
  END IF;

  new_def := replace(old_def, anchor, new_anchor);
  EXECUTE new_def;
END
$mig$;
