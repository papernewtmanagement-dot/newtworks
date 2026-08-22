-- Every solo mode gets a competitive readout.
--
-- Daily Five, The Grid and Spin & Solve are all once-a-day-per-person games, so
-- everybody plays the same kind of round on the same day and the scores are
-- directly comparable. Until now a player finished, saw their own number, and had
-- no idea whether it was any good. This returns today's finished attempts for one
-- mode, best first, with the caller flagged so the screen can highlight them.
--
-- Reads across the whole team on purpose, which is why it resolves the caller
-- itself rather than trusting an id from the screen. Only finished attempts count,
-- so nobody can see a rival's board while it is still being played. Names are
-- first name plus last initial, matching the house convention.

CREATE OR REPLACE FUNCTION public.quiz_mode_day_standings(
  p_mode_key text,
  p_day date DEFAULT NULL
)
 RETURNS TABLE (
   team_member_id uuid,
   name text,
   points integer,
   correct_count integer,
   question_count integer,
   is_me boolean,
   place integer
 )
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency uuid; v_member uuid; v_day date;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency
    FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  v_day := COALESCE(p_day, (now() AT TIME ZONE 'America/Chicago')::date);

  RETURN QUERY
  SELECT qa.team_member_id,
         (t.first_name || ' ' || LEFT(COALESCE(t.last_name, ''), 1) || '.')::text,
         qa.points_earned,
         qa.correct_count,
         qa.question_count,
         (qa.team_member_id = v_member),
         (row_number() OVER (ORDER BY qa.points_earned DESC,
                                      qa.correct_count DESC,
                                      qa.finished_at))::integer
    FROM public.quiz_attempts qa
    JOIN public.team t ON t.id = qa.team_member_id
   WHERE qa.agency_id = v_agency
     AND qa.mode_key = p_mode_key
     AND qa.attempt_day = v_day
     AND qa.finished_at IS NOT NULL
   ORDER BY qa.points_earned DESC, qa.correct_count DESC, qa.finished_at;
END; $function$;

GRANT EXECUTE ON FUNCTION public.quiz_mode_day_standings(text, date) TO authenticated;
