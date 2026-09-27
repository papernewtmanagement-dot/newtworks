DO $mig$
DECLARE
  d  text;
  d2 text;
  a1 text := '"recording_turned_in":"recording turned in",';
  a2 text := '"recording_url":"recording",';
  a3 text := 'opportunity_ref, recording_turned_in, recording_url, notes,';
BEGIN
  -- change_field_label: drop the two labels
  d := pg_get_functiondef('public.change_field_label(text)'::regprocedure);
  IF (length(d) - length(replace(d, a1, ''))) / length(a1) <> 1
     OR (length(d) - length(replace(d, a2, ''))) / length(a2) <> 1 THEN
    RAISE EXCEPTION 'change_field_label: anchors not found exactly once';
  END IF;
  d2 := replace(replace(d, a1, ''), a2, '');
  IF d2 ILIKE '%recording%' THEN RAISE EXCEPTION 'change_field_label: recording still present'; END IF;
  EXECUTE d2;

  -- rp_edit_scorecard: drop the two SET lines
  d := pg_get_functiondef('public.rp_edit_scorecard(uuid,jsonb)'::regprocedure);
  d2 := regexp_replace(d, '\n[ ]*recording_(turned_in|url)[ ]+= CASE[^\n]*', '', 'g');
  IF d2 = d OR d2 ILIKE '%recording%' THEN RAISE EXCEPTION 'rp_edit_scorecard: patch failed'; END IF;
  EXECUTE d2;

  -- rp_entry_for_edit: drop the two keys from the scorecard payload
  d := pg_get_functiondef('public.rp_entry_for_edit(text,uuid)'::regprocedure);
  d2 := regexp_replace(d, '\n[ ]*''recording_turned_in'', f\.recording_turned_in, ''recording_url'', f\.recording_url,', '', 'g');
  IF d2 = d OR d2 ILIKE '%recording%' THEN RAISE EXCEPTION 'rp_entry_for_edit: patch failed'; END IF;
  EXECUTE d2;

  -- rp_log_scorecard: drop the two columns from the insert and their values
  d := pg_get_functiondef('public.rp_log_scorecard(jsonb)'::regprocedure);
  IF (length(d) - length(replace(d, a3, ''))) / length(a3) <> 1 THEN
    RAISE EXCEPTION 'rp_log_scorecard: column anchor not found exactly once';
  END IF;
  d2 := replace(d, a3, 'opportunity_ref, notes,');
  d2 := regexp_replace(d2, '\n[ ]*COALESCE\(\(p->>''recording_turned_in''\)::boolean, false\), NULLIF\(btrim\(COALESCE\(p->>''recording_url'',''''\)\),''''\),', '', 'g');
  IF d2 ILIKE '%recording%' THEN RAISE EXCEPTION 'rp_log_scorecard: patch failed'; END IF;
  EXECUTE d2;
END
$mig$;

ALTER TABLE public.fit_scorecards
  DROP COLUMN IF EXISTS recording_turned_in,
  DROP COLUMN IF EXISTS recording_url;
