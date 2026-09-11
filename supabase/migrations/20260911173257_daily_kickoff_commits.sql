-- Daily Kickoff commits (Peter 2026-09-11).
-- One commit per person per day, saved from the Daily Kickoff page. The next
-- morning the page asks whether it was hit (yes or no only, commits are daily).
-- The midday and EOD reminders list the team's commits for the day. The midday
-- and EOD summaries list them again with the hit marks, because the reminder
-- that carried them is deleted when the summary posts.
-- Send times are untouched: only the message bodies of the two handlers change.

CREATE TABLE IF NOT EXISTS public.daily_commits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  team_member_id uuid NOT NULL REFERENCES public.team(id),
  commit_date date NOT NULL,
  cycle_week smallint CHECK (cycle_week IS NULL OR (cycle_week BETWEEN 1 AND 13)),
  commit_text text NOT NULL CHECK (btrim(commit_text) <> ''),
  source text NOT NULL CHECK (source IN ('example', 'other')),
  hit boolean,
  hit_marked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, team_member_id, commit_date)
);

COMMENT ON TABLE public.daily_commits IS
  'Daily Kickoff commits. One row per teammate per Central-time day. source = example (picked from the week''s list) or other (typed). hit is NULL until the person marks it.';

CREATE INDEX IF NOT EXISTS daily_commits_agency_date_idx
  ON public.daily_commits (agency_id, commit_date);

ALTER TABLE public.daily_commits ENABLE ROW LEVEL SECURITY;

-- Same shape as retention_activity_log / quote_log / sales_log: signed-in
-- teammates read the agency's rows; every write goes through the functions below.
DROP POLICY IF EXISTS daily_commits_auth_read ON public.daily_commits;
CREATE POLICY daily_commits_auth_read ON public.daily_commits
  FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- ── Page: what the signed-in teammate has on file ──────────────────────────
-- today  = today's commit (Central), or null
-- prior  = the latest commit before today within the last 7 days, or null.
--          Monday shows Friday's; the next-morning question hangs off this.
CREATE OR REPLACE FUNCTION public.kickoff_commits_mine()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me uuid := public.current_team_member_id();
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_today_row jsonb; v_prior_row jsonb;
BEGIN
  IF v_me IS NULL THEN
    RETURN jsonb_build_object('member_id', NULL, 'today_date', v_today, 'today', NULL, 'prior', NULL);
  END IF;
  SELECT to_jsonb(c) INTO v_today_row FROM (
    SELECT id, commit_date, cycle_week, commit_text, source, hit, hit_marked_at
    FROM public.daily_commits
    WHERE team_member_id = v_me AND commit_date = v_today
  ) c;
  SELECT to_jsonb(c) INTO v_prior_row FROM (
    SELECT id, commit_date, cycle_week, commit_text, source, hit, hit_marked_at
    FROM public.daily_commits
    WHERE team_member_id = v_me AND commit_date < v_today AND commit_date >= v_today - 7
    ORDER BY commit_date DESC LIMIT 1
  ) c;
  RETURN jsonb_build_object('member_id', v_me, 'today_date', v_today, 'today', v_today_row, 'prior', v_prior_row);
END;
$$;

-- ── Page: save today's commit ──────────────────────────────────────────────
-- Saving again the same day replaces the text and clears any hit mark.
CREATE OR REPLACE FUNCTION public.kickoff_commit_save(p_text text, p_source text, p_week integer DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me uuid := public.current_team_member_id();
  v_agency uuid;
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_text text := btrim(COALESCE(p_text, ''));
  v_row jsonb;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'no team member for this login' USING ERRCODE = '42501';
  END IF;
  IF v_text = '' THEN
    RAISE EXCEPTION 'commit is empty' USING ERRCODE = '22023';
  END IF;
  IF p_source NOT IN ('example', 'other') THEN
    RAISE EXCEPTION 'source must be example or other' USING ERRCODE = '22023';
  END IF;
  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = v_me;

  INSERT INTO public.daily_commits (agency_id, team_member_id, commit_date, cycle_week, commit_text, source)
  VALUES (v_agency, v_me, v_today, p_week, left(v_text, 400), p_source)
  ON CONFLICT (agency_id, team_member_id, commit_date) DO UPDATE
    SET commit_text = EXCLUDED.commit_text,
        source = EXCLUDED.source,
        cycle_week = EXCLUDED.cycle_week,
        hit = NULL,
        hit_marked_at = NULL,
        updated_at = now()
  RETURNING to_jsonb(daily_commits) INTO v_row;

  RETURN v_row;
END;
$$;

-- ── Page: mark a commit hit or missed. Own rows only. ──────────────────────
CREATE OR REPLACE FUNCTION public.kickoff_commit_mark(p_id uuid, p_hit boolean)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me uuid := public.current_team_member_id();
  v_row jsonb;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'no team member for this login' USING ERRCODE = '42501';
  END IF;
  IF p_hit IS NULL THEN
    RAISE EXCEPTION 'hit must be true or false' USING ERRCODE = '22023';
  END IF;
  UPDATE public.daily_commits
  SET hit = p_hit, hit_marked_at = now(), updated_at = now()
  WHERE id = p_id AND team_member_id = v_me
  RETURNING to_jsonb(daily_commits) INTO v_row;
  IF v_row IS NULL THEN
    RAISE EXCEPTION 'commit not found' USING ERRCODE = '22023';
  END IF;
  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.kickoff_commits_mine() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.kickoff_commit_save(text, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.kickoff_commit_mark(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.kickoff_commits_mine() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.kickoff_commit_save(text, text, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.kickoff_commit_mark(uuid, boolean) TO authenticated, service_role;

-- ── Telegram block: the team's commits for one day ─────────────────────────
-- NULL when nobody has a commit on file for that day, so callers can skip it.
-- p_show_hits adds ✅ / ❌ after the name once a commit has been marked.
-- p_html escapes the text for Telegram HTML parse mode (the EOD messages).
CREATE OR REPLACE FUNCTION public.render_daily_commits_block(
  p_agency_id uuid, p_date date, p_show_hits boolean DEFAULT false, p_html boolean DEFAULT false)
RETURNS text
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_row record; v_text text := ''; v_name text; v_body text; v_mark text;
BEGIN
  FOR v_row IN
    SELECT COALESCE(NULLIF(t.nickname, ''), t.first_name) AS display_name,
           t.first_name, c.commit_text, c.hit
    FROM public.daily_commits c
    JOIN public.team t ON t.id = c.team_member_id
    WHERE c.agency_id = p_agency_id
      AND c.commit_date = p_date
      AND t.archived_at IS NULL
      AND COALESCE(t.is_test_user, false) = false
    ORDER BY t.first_name
  LOOP
    v_name := v_row.display_name;
    v_body := v_row.commit_text;
    IF p_html THEN
      v_name := replace(replace(replace(v_name, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
      v_body := replace(replace(replace(v_body, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    END IF;
    v_mark := CASE
      WHEN p_show_hits AND v_row.hit IS TRUE THEN ' ✅'
      WHEN p_show_hits AND v_row.hit IS FALSE THEN ' ❌'
      ELSE '' END;
    v_text := v_text || '• ' || v_name || v_mark || ': ' || v_body || E'\n';
  END LOOP;
  IF v_text = '' THEN RETURN NULL; END IF;
  RETURN E'🎯 Today''s commits\n' || rtrim(v_text, E'\n');
END;
$$;

-- ── Wire the block into the two check-in handlers ─────────────────────────
-- Patched in place from the live definitions so nothing else in either body
-- moves. Each anchor must be found or the migration stops.
DO $do$
DECLARE
  v_def text; v_anchor text; v_add text;
BEGIN
  -- Reminder: midday and EOD list today's commits (no hit marks yet).
  SELECT pg_get_functiondef('public.team_checkin_send_reminder(uuid,uuid)'::regprocedure) INTO v_def;
  IF position('render_daily_commits_block' IN v_def) = 0 THEN
    v_anchor := E'  v_prior_outcome record; v_outcome_line text; v_prior_eod_summary_msg_id bigint;\n';
    IF position(v_anchor IN v_def) = 0 THEN RAISE EXCEPTION 'send_reminder declare anchor not found'; END IF;
    v_def := replace(v_def, v_anchor, v_anchor || E'  v_commits text;\n');

    v_anchor := E'\n  SELECT COUNT(*) INTO v_pending_votes\n';
    IF position(v_anchor IN v_def) = 0 THEN RAISE EXCEPTION 'send_reminder votes anchor not found'; END IF;
    v_add := E'\n  -- Today''s commits ride on the midday and EOD reminders (Peter 2026-09-11).\n'
          || E'  IF v_checkin_type IN (''midday'', ''eod'') THEN\n'
          || E'    v_commits := public.render_daily_commits_block(p_agency_id, v_today, false, v_checkin_type = ''eod'');\n'
          || E'    IF v_commits IS NOT NULL THEN\n'
          || E'      v_text := v_text || E''\\n\\n'' || v_commits;\n'
          || E'    END IF;\n'
          || E'  END IF;\n';
    v_def := replace(v_def, v_anchor, v_add || v_anchor);
    EXECUTE v_def;
  END IF;

  -- Summary: midday and EOD list the commits again, with hit marks, since the
  -- reminder that carried them is deleted when the summary posts.
  SELECT pg_get_functiondef('public.team_checkin_compile_results(uuid,uuid)'::regprocedure) INTO v_def;
  IF position('render_daily_commits_block' IN v_def) = 0 THEN
    v_anchor := E'  v_reminder_msg_id bigint; v_tag_msg_id bigint; v_midday_summary_msg_id bigint;\n';
    IF position(v_anchor IN v_def) = 0 THEN RAISE EXCEPTION 'compile declare anchor not found'; END IF;
    v_def := replace(v_def, v_anchor, v_anchor || E'  v_commits text;\n');

    v_anchor := E'  -- Reminder is about to be deleted, so anything that still needs saying moves\n';
    IF position(v_anchor IN v_def) = 0 THEN RAISE EXCEPTION 'compile deposit anchor not found'; END IF;
    v_add := E'  -- The team''s commits and whether each was hit. The reminder that listed\n'
          || E'  -- them is deleted below, so they ride on the results (Peter 2026-09-11).\n'
          || E'  IF v_checkin_type IN (''midday'', ''eod'') THEN\n'
          || E'    v_commits := public.render_daily_commits_block(p_agency_id, v_today, true, v_checkin_type = ''eod'');\n'
          || E'    IF v_commits IS NOT NULL THEN\n'
          || E'      v_text := v_text || E''\\n\\n'' || v_commits;\n'
          || E'    END IF;\n'
          || E'  END IF;\n\n';
    v_def := replace(v_def, v_anchor, v_add || v_anchor);
    EXECUTE v_def;
  END IF;
END $do$;
