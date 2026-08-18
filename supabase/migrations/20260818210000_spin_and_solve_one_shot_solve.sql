-- Solving is one-shot, matching the real show: attempting to solve and
-- missing ends the term immediately (control passes), it does not just cost
-- one guess the way a wrong letter does. Spinning was already unlimited
-- (pending_spin clears after every guess, hit or miss, so the wheel is
-- always spinnable again) -- this patch only changes the solve branch.
CREATE OR REPLACE FUNCTION public.quiz_phrase_solve(p_attempt_id uuid, p_item_id uuid, p_text text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_member  uuid;
  v_agency  uuid;
  v_att     public.quiz_attempts;
  v_item    public.quiz_items;
  v_phrase  text;
  v_prog    jsonb;
  v_guessed text[];
  v_misses  int;
  v_solved  boolean;
  v_money   int;
  v_right   boolean;
  v_over    boolean;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  SELECT * INTO v_att FROM public.quiz_attempts
   WHERE id = p_attempt_id AND team_member_id = v_member AND agency_id = v_agency
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'that game was not found, or it is not yours';
  END IF;
  IF v_att.finished_at IS NOT NULL THEN
    RAISE EXCEPTION 'that game is already finished';
  END IF;
  IF NOT (COALESCE(v_att.context -> 'item_ids', '[]'::jsonb) ? p_item_id::text) THEN
    RAISE EXCEPTION 'that term is not part of this game';
  END IF;
  IF EXISTS (SELECT 1 FROM public.quiz_answers
              WHERE attempt_id = p_attempt_id AND item_id = p_item_id) THEN
    RAISE EXCEPTION 'that term is already done';
  END IF;

  SELECT * INTO v_item FROM public.quiz_items WHERE id = p_item_id;
  IF v_item.shape <> 'phrase' OR v_item.phrase_answer IS NULL THEN
    RAISE EXCEPTION 'that question has no hidden term';
  END IF;
  v_phrase := public.quiz_phrase_normalize(v_item.phrase_answer);

  v_prog    := COALESCE(v_att.context -> 'phrase_progress' -> (p_item_id::text), '{}'::jsonb);
  v_guessed := COALESCE(ARRAY(SELECT jsonb_array_elements_text(v_prog -> 'guessed')), ARRAY[]::text[]);
  v_misses  := COALESCE((v_prog ->> 'misses')::int, 0);
  v_solved  := COALESCE((v_prog ->> 'solved')::boolean, false);
  v_money   := COALESCE((v_prog ->> 'round_money')::int, 0);

  IF v_solved OR v_misses >= 4 THEN
    RAISE EXCEPTION 'the term is already revealed';
  END IF;

  v_right := (public.quiz_phrase_normalize(p_text) = v_phrase);
  IF v_right THEN
    v_solved  := true;
    v_guessed := ARRAY(SELECT DISTINCT t.ch
                         FROM regexp_split_to_table(v_phrase, '') AS t(ch)
                        WHERE t.ch ~ '[A-Z]');
  ELSE
    -- One guess to solve, same as the real show: missing ends the term right
    -- here, it does not just cost a single letter's worth of a guess.
    v_misses := 4;
  END IF;
  v_over := v_solved OR v_misses >= 4;

  UPDATE public.quiz_attempts
     SET context = COALESCE(context, '{}'::jsonb)
                   || jsonb_build_object('phrase_progress',
                        COALESCE(context -> 'phrase_progress', '{}'::jsonb)
                        || jsonb_build_object(p_item_id::text, jsonb_build_object(
                             'guessed', to_jsonb(v_guessed),
                             'misses',  v_misses,
                             'solved',  v_solved,
                             'round_money', v_money,
                             'pending_spin', COALESCE(v_att.context -> 'phrase_progress' -> (p_item_id::text) -> 'pending_spin', 'null'::jsonb))))
   WHERE id = p_attempt_id;

  RETURN jsonb_build_object(
    'correct', v_right,
    'display', public.quiz_phrase_display(v_phrase, v_guessed, v_over),
    'guessed', to_jsonb(v_guessed),
    'misses',  v_misses,
    'solved',  v_solved,
    'over',    v_over,
    'round_money', v_money,
    'answer',  CASE WHEN v_over THEN v_phrase ELSE NULL END);
END; $function$;
