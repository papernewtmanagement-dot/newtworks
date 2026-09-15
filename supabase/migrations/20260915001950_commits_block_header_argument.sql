-- render_daily_commits_block gains a header argument so the morning kickoff can
-- label the block with the PRIOR workday's date instead of "Today's commits".
-- CREATE OR REPLACE cannot add a parameter, so drop and recreate. The only
-- caller, team_checkin_build_results_message, passes four positional arguments
-- and keeps working unchanged against the new defaulted fifth.
DROP FUNCTION IF EXISTS public.render_daily_commits_block(uuid, date, boolean, boolean);

CREATE OR REPLACE FUNCTION public.render_daily_commits_block(
  p_agency_id uuid,
  p_date date,
  p_show_hits boolean DEFAULT false,
  p_html boolean DEFAULT false,
  p_header text DEFAULT '🎯 Today''s commits'
)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_row record; v_text text := ''; v_name text; v_body text; v_mark text;
BEGIN
  FOR v_row IN SELECT * FROM public.daily_commits_for_day(p_agency_id, p_date)
  LOOP
    v_name := v_row.display_name;
    v_body := COALESCE(btrim(v_row.commit_text), '');
    IF p_html THEN
      v_name := replace(replace(replace(v_name, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
      v_body := replace(replace(replace(v_body, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    END IF;
    IF v_body = '' THEN
      v_mark := ' ⚠️';
      v_body := 'Missing';
    ELSE
      v_mark := CASE
        WHEN p_show_hits AND v_row.hit IS TRUE THEN ' ✅'
        WHEN p_show_hits AND v_row.hit IS FALSE THEN ' ❌'
        ELSE '' END;
    END IF;
    v_text := v_text || '• ' || v_name || v_mark || ': ' || v_body || E'\n';
  END LOOP;
  IF v_text = '' THEN RETURN NULL; END IF;
  RETURN p_header || E'\n' || rtrim(v_text, E'\n');
END;
$function$;
