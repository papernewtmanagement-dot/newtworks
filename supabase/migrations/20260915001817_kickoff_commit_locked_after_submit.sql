-- A commit cannot be changed once it is submitted (Peter 2026-09-14).
-- kickoff_commit_save used to upsert, which silently replaced the day's commit
-- and reset the hit mark. It now refuses a second save for the same Central day.
CREATE OR REPLACE FUNCTION public.kickoff_commit_save(p_text text, p_source text, p_week integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

  IF EXISTS (
    SELECT 1 FROM public.daily_commits
    WHERE team_member_id = v_me AND commit_date = v_today
  ) THEN
    RAISE EXCEPTION 'your commit for today is already saved and cannot be changed'
      USING ERRCODE = '23505';
  END IF;

  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = v_me;

  INSERT INTO public.daily_commits (agency_id, team_member_id, commit_date, cycle_week, commit_text, source)
  VALUES (v_agency, v_me, v_today, p_week, left(v_text, 400), p_source)
  RETURNING to_jsonb(daily_commits) INTO v_row;

  RETURN v_row;
END;
$function$;