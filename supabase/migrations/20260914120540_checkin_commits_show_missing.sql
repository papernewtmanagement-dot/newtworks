-- Daily commits block: list everyone expected on today's check-ins, not just
-- the people who submitted. No commit saved for the day -> the person still
-- shows, marked "Missing" with a warning icon (Peter 2026-09-14).
-- Roster comes from get_expected_teammates 'work_checkin', the same list the
-- tag-missing nag uses, so approved full-day time off drops a person from the
-- block instead of flagging them. Anyone who saved a commit is always shown,
-- even if they are off that roster.
CREATE OR REPLACE FUNCTION public.render_daily_commits_block(p_agency_id uuid, p_date date, p_show_hits boolean DEFAULT false, p_html boolean DEFAULT false)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_row record; v_text text := ''; v_name text; v_body text; v_mark text;
BEGIN
  FOR v_row IN
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
    SELECT r.display_name, r.first_name, c.commit_text, c.hit
    FROM roster r
    LEFT JOIN public.daily_commits c
      ON c.team_member_id = r.team_id
     AND c.agency_id      = p_agency_id
     AND c.commit_date    = p_date
    ORDER BY r.first_name
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