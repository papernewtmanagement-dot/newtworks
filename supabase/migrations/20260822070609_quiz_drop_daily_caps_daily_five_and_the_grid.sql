-- Peter's call 2026-08-22: drop the once-a-day caps on Daily Five and The Grid
-- entirely. The Grid's cap had no recorded reason anywhere in the migration
-- history or the rulings; Daily Five's was Ruling 22. Both are removed on his
-- explicit instruction after the trade-offs were put to him.
--
-- Why this had to happen before the multiplayer room could reach these two
-- modes: the caps were UNIQUE INDEXES, so they applied to every game record
-- regardless of which function wrote it. The room spine opens one game record
-- per player inside a single transaction, so one player who had already played
-- that day made the whole room fail to start for everybody.

DROP INDEX IF EXISTS public.uq_quiz_attempts_daily_five;
DROP INDEX IF EXISTS public.uq_quiz_attempts_the_grid;

-- Those two unique indexes were also the lookup path for the day standings
-- board and for the resume checks below. Replace with a plain index so both
-- stay fast now that the unique ones are gone.
CREATE INDEX IF NOT EXISTS ix_quiz_attempts_agency_mode_day
  ON public.quiz_attempts (agency_id, mode_key, attempt_day);

-- ---------------------------------------------------------------------------
-- Daily Five solo start: a finished game no longer refuses. An unfinished one
-- still RESUMES on its pinned questions, because bailing out mid-game must
-- never deal a fresh set. Room games are excluded from the resume lookup -
-- those are opened by the room spine, never by this function.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quiz_start_daily_attempt()
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_agency uuid; v_member uuid; v_existing uuid;
  v_shapes text[]; v_count int; v_ids jsonb; v_new uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency
    FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  SELECT id INTO v_existing
    FROM public.quiz_attempts
   WHERE agency_id = v_agency AND team_member_id = v_member
     AND mode_key = 'daily_five'
     AND attempt_day = ((now() AT TIME ZONE 'America/Chicago')::date)
     AND finished_at IS NULL
     AND (context ->> 'room_id') IS NULL
   ORDER BY started_at DESC
   LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT COALESCE(allowed_shapes, ARRAY['choice']::text[]),
         COALESCE(question_count, 5)
    INTO v_shapes, v_count
    FROM public.quiz_modes
   WHERE agency_id = v_agency AND mode_key = 'daily_five';
  IF v_shapes IS NULL OR array_length(v_shapes, 1) IS NULL THEN
    v_shapes := ARRAY['choice']::text[];
  END IF;
  IF v_count IS NULL OR v_count < 1 THEN v_count := 5; END IF;

  SELECT jsonb_agg(p.id) INTO v_ids
    FROM (SELECT qi.id
            FROM public.quiz_items qi
           WHERE qi.agency_id = v_agency AND qi.status = 'approved'
             AND qi.report_blocked = false
             AND qi.shape = ANY (v_shapes)
           ORDER BY random() LIMIT v_count) p;

  IF v_ids IS NULL OR jsonb_array_length(v_ids) < v_count THEN
    RAISE EXCEPTION 'not enough questions ready yet - need % , have %',
      v_count, COALESCE(jsonb_array_length(v_ids), 0);
  END IF;

  INSERT INTO public.quiz_attempts
    (agency_id, team_member_id, mode_key, context)
  VALUES (v_agency, v_member, 'daily_five', jsonb_build_object('item_ids', v_ids))
  RETURNING id INTO v_new;
  RETURN v_new;
END; $$;

-- ---------------------------------------------------------------------------
-- The Grid solo start: same change, same reasoning. Board drawing logic is
-- carried over byte-identical from migration 20260811231617 - only the
-- refusal branch and the resume lookup changed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quiz_start_grid_attempt()
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_agency uuid; v_member uuid; v_existing uuid;
  v_cats text[]; v_cat text; v_items jsonb;
  v_board jsonb := '[]'::jsonb; v_points jsonb := '[]'::jsonb;
  v_new uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency
    FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  SELECT id INTO v_existing
    FROM public.quiz_attempts
   WHERE agency_id = v_agency AND team_member_id = v_member
     AND mode_key = 'the_grid'
     AND attempt_day = ((now() AT TIME ZONE 'America/Chicago')::date)
     AND finished_at IS NULL
     AND (context ->> 'room_id') IS NULL
   ORDER BY started_at DESC
   LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT array_agg(c.category ORDER BY c.n DESC, c.category)
    INTO v_cats
    FROM (SELECT qi.category, COUNT(*) AS n
            FROM public.quiz_items qi
           WHERE qi.agency_id = v_agency AND qi.status = 'approved'
             AND qi.report_blocked = false AND qi.category IS NOT NULL
           GROUP BY qi.category
          HAVING COUNT(*) >= 5
           ORDER BY COUNT(*) DESC, qi.category
           LIMIT 5) c;

  IF v_cats IS NULL OR array_length(v_cats, 1) < 3 THEN
    RAISE EXCEPTION 'the board needs at least three categories with five approved questions each (have %)',
      COALESCE(array_length(v_cats, 1), 0);
  END IF;

  FOREACH v_cat IN ARRAY v_cats LOOP
    SELECT jsonb_agg(jsonb_build_object('item_id', y.id, 'points', y.rn * 10)
                     ORDER BY y.rn)
      INTO v_items
      FROM (
        SELECT p.id,
               row_number() OVER (ORDER BY CASE p.difficulty
                                             WHEN 'basic' THEN 1
                                             WHEN 'intermediate' THEN 2
                                             ELSE 3 END, p.id) AS rn
          FROM (SELECT qi.id, qi.difficulty
                  FROM public.quiz_items qi
                 WHERE qi.agency_id = v_agency AND qi.status = 'approved'
                   AND qi.report_blocked = false AND qi.category = v_cat
                 ORDER BY random() LIMIT 5) p
      ) y;

    v_board  := v_board || jsonb_build_array(
                  jsonb_build_object('category', v_cat, 'clues', v_items));
    v_points := v_points || v_items;
  END LOOP;

  INSERT INTO public.quiz_attempts
    (agency_id, team_member_id, mode_key, context)
  VALUES (v_agency, v_member, 'the_grid',
          jsonb_build_object(
            'board', v_board,
            'board_points', v_points,
            'item_ids', (SELECT jsonb_agg(e->'item_id')
                           FROM jsonb_array_elements(v_points) e)))
  RETURNING id INTO v_new;
  RETURN v_new;
END; $$;

-- ---------------------------------------------------------------------------
-- Day standings: one row per PERSON, their best game that day. Before the caps
-- were dropped this function could rely on there being exactly one game per
-- person per day, so it selected rows straight out of the table. Without the
-- caps a person who plays three times would have appeared three times.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.quiz_mode_day_standings(p_mode_key text, p_day date DEFAULT NULL::date)
RETURNS TABLE(team_member_id uuid, name text, points integer, correct_count integer,
              question_count integer, is_me boolean, place integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
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
  WITH best AS (
    SELECT DISTINCT ON (qa.team_member_id)
           qa.team_member_id AS member_id,
           qa.points_earned, qa.correct_count, qa.question_count, qa.finished_at
      FROM public.quiz_attempts qa
     WHERE qa.agency_id = v_agency
       AND qa.mode_key = p_mode_key
       AND qa.attempt_day = v_day
       AND qa.finished_at IS NOT NULL
     ORDER BY qa.team_member_id, qa.points_earned DESC,
              qa.correct_count DESC, qa.finished_at
  )
  SELECT b.member_id,
         (t.first_name || ' ' || LEFT(COALESCE(t.last_name, ''), 1) || '.')::text,
         b.points_earned,
         b.correct_count,
         b.question_count,
         (b.member_id = v_member),
         (row_number() OVER (ORDER BY b.points_earned DESC,
                                      b.correct_count DESC,
                                      b.finished_at))::integer
    FROM best b
    JOIN public.team t ON t.id = b.member_id
   ORDER BY b.points_earned DESC, b.correct_count DESC, b.finished_at;
END; $$;

REVOKE ALL ON FUNCTION public.quiz_start_daily_attempt() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.quiz_start_daily_attempt() FROM anon;
GRANT EXECUTE ON FUNCTION public.quiz_start_daily_attempt() TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.quiz_start_grid_attempt() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.quiz_start_grid_attempt() FROM anon;
GRANT EXECUTE ON FUNCTION public.quiz_start_grid_attempt() TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.quiz_mode_day_standings(text, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.quiz_mode_day_standings(text, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.quiz_mode_day_standings(text, date) TO authenticated, service_role;
