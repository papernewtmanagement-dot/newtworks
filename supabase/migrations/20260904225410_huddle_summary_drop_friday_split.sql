-- Peter ruling 2026-09-04: the Daily Kickoff is 30 minutes EVERY weekday, Friday included.
-- The old "30 min Mon-Thu, 20 min Fri retrospective" split is dead and must not be reintroduced.
-- The live Google Calendar series (fudvjv7v4mnde3cq28pcq4beqs_R20260902T133000) has always been
-- a single 8:30-9:00 recurrence Mon-Fri; the 20-minute Friday only ever existed in this render
-- string and in agency_huddle_config.duration_fri_min, which now equals duration_regular_min.
CREATE OR REPLACE FUNCTION public.render_huddle_summary_md(p_agency_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v public.agency_huddle_config%ROWTYPE;
  v_time TEXT;
  v_days TEXT;
  v_leader_name TEXT;
BEGIN
  SELECT * INTO v FROM public.agency_huddle_config WHERE agency_id = p_agency_id;
  IF NOT FOUND THEN
    RETURN '⚠️ Kickoff config not set.';
  END IF;

  v_time := TO_CHAR(v.start_time_local, 'FMHH12:MI AM');

  IF v.days_of_week @> ARRAY['MO','TU','WE','TH','FR']
     AND array_length(v.days_of_week, 1) = 5 THEN
    v_days := 'every weekday';
  ELSE
    v_days := array_to_string(v.days_of_week, ', ');
  END IF;

  IF v.current_week_leader_team_id IS NOT NULL THEN
    SELECT COALESCE(NULLIF(nickname,''), first_name) INTO v_leader_name
    FROM public.team WHERE id = v.current_week_leader_team_id;
  END IF;

  RETURN
    '**📅 ' || v_time || ' ' || v_days || '** — '
    || v.duration_regular_min || ' min'
    || CASE WHEN COALESCE(v.meeting_notes,'') <> ''
            THEN E'  \n*' || v.meeting_notes || '*'
            ELSE '' END
    || E'\n\n👤 **This week''s leader:** '
       || COALESCE(v_leader_name, '_not set — UPDATE `agency_huddle_config.current_week_leader_team_id` to fill_')
    || E'\n\n📄 **Full rhythm:** Daily Kickoff (Processes)'
    || E'\n\n> ⚙️ Auto-generated from `agency_huddle_config`. Don''t hand-edit between the delimiters — edits will be overwritten on next config change.';
END;
$function$;
