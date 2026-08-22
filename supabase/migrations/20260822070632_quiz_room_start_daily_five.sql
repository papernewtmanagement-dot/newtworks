-- Step 3 of Peter's Play-tab sequence, mode 1 of 4: Daily Five gets a
-- multiplayer branch on the shared room spine shipped 2026-08-22.
--
-- THE PATTERN, and the one the other three modes will copy: this function owns
-- the question draw and nothing else. It draws ONE set of questions for the
-- whole room, then hands off to _quiz_room_begin, which flips the room from
-- waiting to playing and opens one game record per player carrying that same
-- set. Because each player ends up with an ordinary game record, every screen
-- and every scoring function downstream - quiz_play_state, quiz_submit_answer,
-- quiz_finish_attempt, the day board, the weekly points - keeps working with
-- no change at all. Multiplayer scoring is not reinvented anywhere.
--
-- Everyone in the room gets the SAME questions. That is what makes it a shared
-- game rather than several solo games happening at once.

CREATE OR REPLACE FUNCTION public.quiz_room_start_daily_five(p_room_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_room public.quiz_rooms;
  v_shapes text[]; v_count int; v_ids jsonb;
BEGIN
  -- Resolves the signed-in person, confirms the room is in their agency, locks
  -- the row against a double start, and enforces host-only.
  v_room := public._quiz_room_locked(p_room_id, true);

  IF v_room.mode_key <> 'daily_five' THEN
    RAISE EXCEPTION 'that room is not a Daily Five room';
  END IF;
  IF v_room.status <> 'lobby' THEN
    RAISE EXCEPTION 'this game has already started';
  END IF;
  IF jsonb_array_length(COALESCE(v_room.players, '[]'::jsonb)) < 2 THEN
    RAISE EXCEPTION 'a team game needs at least two players - wait for someone to join';
  END IF;

  SELECT COALESCE(allowed_shapes, ARRAY['choice']::text[]),
         COALESCE(question_count, 5)
    INTO v_shapes, v_count
    FROM public.quiz_modes
   WHERE agency_id = v_room.agency_id AND mode_key = 'daily_five';
  IF v_shapes IS NULL OR array_length(v_shapes, 1) IS NULL THEN
    v_shapes := ARRAY['choice']::text[];
  END IF;
  IF v_count IS NULL OR v_count < 1 THEN v_count := 5; END IF;

  SELECT jsonb_agg(p.id) INTO v_ids
    FROM (SELECT qi.id
            FROM public.quiz_items qi
           WHERE qi.agency_id = v_room.agency_id
             AND qi.status = 'approved'
             AND qi.report_blocked = false
             AND qi.shape = ANY (v_shapes)
           ORDER BY random() LIMIT v_count) p;

  IF v_ids IS NULL OR jsonb_array_length(v_ids) < v_count THEN
    RAISE EXCEPTION 'not enough questions ready yet - need % , have %',
      v_count, COALESCE(jsonb_array_length(v_ids), 0);
  END IF;

  RETURN public._quiz_room_begin(
    p_room_id,
    jsonb_build_object('question_count', v_count),
    jsonb_build_object('item_ids', v_ids));
END; $$;

REVOKE ALL ON FUNCTION public.quiz_room_start_daily_five(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.quiz_room_start_daily_five(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.quiz_room_start_daily_five(uuid) TO authenticated, service_role;
