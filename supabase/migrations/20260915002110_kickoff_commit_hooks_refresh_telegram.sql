-- Saving or marking a commit from the browser refreshes the standing kickoff
-- message. The refresh is wrapped: a Telegram problem must never stop someone
-- saving or marking their commit.
CREATE OR REPLACE FUNCTION public.kickoff_commit_mark(p_id uuid, p_hit boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_me uuid := public.current_team_member_id();
  v_agency uuid;
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

  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = v_me;
  BEGIN
    PERFORM public.kickoff_refresh_telegram(v_agency);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN v_row;
END;
$function$;

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

  BEGIN
    PERFORM public.kickoff_refresh_telegram(v_agency);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN v_row;
END;
$function$;
