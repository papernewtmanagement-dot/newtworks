-- Step 3, mode 3 of 4: Spin & Solve gets a multiplayer branch on the shared
-- room spine. Same pattern as quiz_room_start_daily_five - this function owns
-- the draw and nothing else, then hands off to _quiz_room_begin, which opens
-- one ordinary game record per player carrying the same terms.
--
-- The once-a-day rule for this mode lives INSIDE quiz_start_spin_attempt
-- rather than as a database index, which is why a room here needed no cap
-- change: a new function simply does not perform that check. The solo cap is
-- untouched and still enforced, for the reason recorded in ruling 71(g) - only
-- 37 hidden terms exist and a repeated term is worthless once memorised.
--
-- phrase_answer NOT NULL is carried over from the solo draw deliberately: the
-- shape constraint already guarantees it, but a future allowed_shapes edit
-- must not be able to deal a term-less item into a hidden-term game.

CREATE OR REPLACE FUNCTION public.quiz_room_start_spin_and_solve(p_room_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_room public.quiz_rooms;
  v_shapes text[]; v_count int; v_ids jsonb;
BEGIN
  v_room := public._quiz_room_locked(p_room_id, true);

  IF v_room.mode_key <> 'spin_and_solve' THEN
    RAISE EXCEPTION 'that room is not a Spin & Solve room';
  END IF;
  IF v_room.status <> 'lobby' THEN
    RAISE EXCEPTION 'this game has already started';
  END IF;
  IF jsonb_array_length(COALESCE(v_room.players, '[]'::jsonb)) < 2 THEN
    RAISE EXCEPTION 'a team game needs at least two players - wait for someone to join';
  END IF;

  SELECT COALESCE(allowed_shapes, ARRAY['phrase']::text[]),
         COALESCE(question_count, 6)
    INTO v_shapes, v_count
    FROM public.quiz_modes
   WHERE agency_id = v_room.agency_id AND mode_key = 'spin_and_solve';
  IF v_shapes IS NULL OR array_length(v_shapes, 1) IS NULL THEN
    v_shapes := ARRAY['phrase']::text[];
  END IF;
  IF v_count IS NULL OR v_count < 1 THEN v_count := 6; END IF;

  SELECT jsonb_agg(x.id) INTO v_ids
    FROM (SELECT qi.id
            FROM public.quiz_items qi
           WHERE qi.agency_id = v_room.agency_id
             AND qi.status = 'approved'
             AND qi.report_blocked = false
             AND qi.shape = ANY (v_shapes)
             AND qi.phrase_answer IS NOT NULL
           ORDER BY random()
           LIMIT v_count) x;

  IF v_ids IS NULL OR jsonb_array_length(v_ids) < v_count THEN
    RAISE EXCEPTION 'spin and solve needs % approved terms (have %)',
      v_count, COALESCE(jsonb_array_length(v_ids), 0);
  END IF;

  RETURN public._quiz_room_begin(
    p_room_id,
    jsonb_build_object('question_count', v_count),
    jsonb_build_object('item_ids', v_ids));
END; $$;

REVOKE ALL ON FUNCTION public.quiz_room_start_spin_and_solve(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.quiz_room_start_spin_and_solve(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.quiz_room_start_spin_and_solve(uuid) TO authenticated, service_role;
