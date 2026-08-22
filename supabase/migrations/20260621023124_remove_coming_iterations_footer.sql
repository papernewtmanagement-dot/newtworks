-- Surgical removal of the "Coming in upcoming iterations" footer block from compose_weekly_cpr_html.
DO $patch$
DECLARE
  v_old text;
  v_new text := '';
  v_def text;
  v_count int;
BEGIN
  v_old :=
       E'  v_html := v_html\n'
    || E'    || \'<hr style="border:none;border-top:1px solid #e2e8f0;margin:20px 0">\'\n'
    || E'    || \'<div style="font-size:11px;color:#94a3b8;font-style:italic;margin:8px 0">Coming in upcoming iterations: Sales Points History (rolling averages), Leaderboards &amp; All-Stars, Prize Cart. Full data is on the <a href="\' || v_cpr_url || \'" style="color:#64748b">CPR detail page</a>.</div>\';\n';

  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid
   WHERE n.nspname='public' AND p.proname='compose_weekly_cpr_html';

  v_count := (LENGTH(v_def) - LENGTH(REPLACE(v_def, v_old, ''))) / LENGTH(v_old);
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Footer anchor not found exactly once (found %)', v_count;
  END IF;

  EXECUTE REPLACE(v_def, v_old, v_new);
END
$patch$;

-- Verify gone
SELECT
  (pg_get_functiondef(p.oid) LIKE '%Coming in upcoming iterations%') AS footer_still_present
FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid
WHERE n.nspname='public' AND p.proname='compose_weekly_cpr_html';
