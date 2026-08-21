-- Surgically replace the Team Activity Result row in compose_weekly_cpr_html
-- with a single colspan=4 centered cell (no "Result" label, matches page).
DO $migration$
DECLARE
  v_old text;
  v_new text;
  v_def text;
  v_new_def text;
  v_count int;
BEGIN
  v_old :=
       E'    || \'<tr>\'\n'
    || E'    || \'<td style="padding:6px 10px;font-weight:700;color:#334155">Result</td>\'\n'
    || E'    || \'<td style="padding:6px 10px;text-align:right;color:#334155"></td>\'\n'
    || E'    || \'<td colspan="2" style="padding:6px 10px;text-align:center;font-weight:700;color:\'\n';

  v_new :=
       E'    || \'<tr>\'\n'
    || E'    || \'<td colspan="4" style="padding:6px 10px;text-align:center;font-weight:700;color:\'\n';

  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
   WHERE n.nspname='public' AND p.proname='compose_weekly_cpr_html';

  -- Make sure the anchor exists exactly once
  v_count := (LENGTH(v_def) - LENGTH(REPLACE(v_def, v_old, ''))) / LENGTH(v_old);
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Anchor for Result row not found exactly once (found %)', v_count;
  END IF;

  v_new_def := REPLACE(v_def, v_old, v_new);
  EXECUTE v_new_def;
END
$migration$;

-- Verify the change landed
SELECT
  position('Result</td>' IN pg_get_functiondef(p.oid)) AS old_label_pos,
  position('colspan="4"' IN pg_get_functiondef(p.oid)) AS new_colspan_pos
FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid
WHERE n.nspname='public' AND p.proname='compose_weekly_cpr_html';
