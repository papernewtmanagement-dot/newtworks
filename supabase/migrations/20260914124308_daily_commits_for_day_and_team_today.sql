-- One source for "who was expected today and what did they commit to".
-- render_daily_commits_block (Telegram) and kickoff_commits_today (page +
-- dashboard) both read it, so the roster can never drift between surfaces.
CREATE OR REPLACE FUNCTION public.daily_commits_for_day(p_agency_id uuid, p_date date)
RETURNS TABLE (team_id uuid, first_name text, display_name text, commit_text text, hit boolean)
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH roster AS (
    SELECT e.team_id, e.first_name::text AS first_name, e.display_name::text AS display_name
    FROM public.get_expected_teammates(p_agency_id, 'work_checkin', p_date, NULL) e
    UNION
    SELECT t.id, t.first_name::text, COALESCE(NULLIF(t.nickname, ''), t.first_name)::text
    FROM public.daily_commits c
    JOIN public.team t ON t.id = c.team_member_id
    WHERE c.agency_id = p_agency_id
      AND c.commit_date = p_date
      AND t.archived_at IS NULL
      AND COALESCE(t.is_test_user, false) = false
  )
  SELECT r.team_id, r.first_name, r.display_name, c.commit_text, c.hit
  FROM roster r
  LEFT JOIN public.daily_commits c
    ON c.team_member_id = r.team_id
   AND c.agency_id      = p_agency_id
   AND c.commit_date    = p_date
  ORDER BY r.first_name;
$function$;

CREATE OR REPLACE FUNCTION public.render_daily_commits_block(p_agency_id uuid, p_date date, p_show_hits boolean DEFAULT false, p_html boolean DEFAULT false)
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
  RETURN E'🎯 Today''s commits\n' || rtrim(v_text, E'\n');
END;
$function$;

-- Everyone's commit for today, for the bottom of the Daily Kickoff page and the
-- dashboard. Read-only; marking a commit still goes through kickoff_commit_mark.
CREATE OR REPLACE FUNCTION public.kickoff_commits_today()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_me uuid := public.current_team_member_id();
  v_agency uuid;
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_people jsonb;
BEGIN
  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = v_me;
  IF v_agency IS NULL THEN
    RETURN jsonb_build_object('today_date', v_today, 'me', NULL, 'people', '[]'::jsonb);
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'team_member_id', d.team_id,
           'name',           d.display_name,
           'commit_text',    d.commit_text,
           'hit',            d.hit
         ) ORDER BY d.first_name), '[]'::jsonb)
  INTO v_people
  FROM public.daily_commits_for_day(v_agency, v_today) d;
  RETURN jsonb_build_object('today_date', v_today, 'me', v_me, 'people', v_people);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.kickoff_commits_today() TO authenticated;
GRANT EXECUTE ON FUNCTION public.daily_commits_for_day(uuid, date) TO authenticated;
