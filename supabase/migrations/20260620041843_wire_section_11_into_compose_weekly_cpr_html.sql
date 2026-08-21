-- Wire Section 11 into compose_weekly_cpr_html with two surgical edits.
-- Uses pg_get_functiondef + replace() to avoid copy/pasting the 31K-char function body.

DO $migration$
DECLARE
  v_src       text;
  v_new       text;
  v_anchor_1  text;
  v_replace_1 text;
  v_anchor_2  text;
  v_replace_2 text;
  v_changed_1 boolean;
  v_changed_2 boolean;
BEGIN
  -- Pull current definition
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND proname = 'compose_weekly_cpr_html';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'compose_weekly_cpr_html not found';
  END IF;

  -- EDIT 1: Insert Section 11 render right after Agency Performance section ends.
  -- The Agency Performance block ends with: || v_perf_rows || '</tbody></table></div>';\n  END IF;
  -- We insert a new v_html append right after the END IF.
  v_anchor_1 := E'|| v_perf_rows || ''</tbody></table></div>'';\n  END IF;\n\n  v_html := v_html\n    || ''<div style="margin:14px 0;padding:12px 14px;background:#f8fafc;border-radius:8px"';

  v_replace_1 := E'|| v_perf_rows || ''</tbody></table></div>'';\n  END IF;\n\n  -- Section 11: SMVC & Scorecard (rendered via helper)\n  v_html := v_html || public.render_cpr_section_11_html(p_agency_id, p_week_ending_date);\n\n  v_html := v_html\n    || ''<div style="margin:14px 0;padding:12px 14px;background:#f8fafc;border-radius:8px"';

  v_changed_1 := POSITION(v_anchor_1 IN v_src) > 0;
  v_new := replace(v_src, v_anchor_1, v_replace_1);

  -- EDIT 2: Remove "SMVC &amp; Scorecard, " from the omitted-sections line
  v_anchor_2 := 'Coming in upcoming iterations: SMVC &amp; Scorecard, Sales Points History';
  v_replace_2 := 'Coming in upcoming iterations: Sales Points History';

  v_changed_2 := POSITION(v_anchor_2 IN v_new) > 0;
  v_new := replace(v_new, v_anchor_2, v_replace_2);

  IF NOT v_changed_1 THEN
    RAISE EXCEPTION 'Section 11 insertion anchor not found in compose_weekly_cpr_html';
  END IF;
  IF NOT v_changed_2 THEN
    RAISE EXCEPTION 'Omitted-sections anchor not found in compose_weekly_cpr_html';
  END IF;

  -- Apply
  EXECUTE v_new;

  RAISE NOTICE 'compose_weekly_cpr_html updated: Section 11 wired in, omitted list updated';
END;
$migration$;
