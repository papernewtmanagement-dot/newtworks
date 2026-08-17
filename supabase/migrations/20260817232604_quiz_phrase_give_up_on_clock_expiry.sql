-- The hidden-term half has its own clock. When it runs out the term is shown and
-- the player moves on to the meaning question with no solve bonus - which is
-- what the screen already did, except it did it by revealing a term it was
-- holding locally. It no longer holds the term, so ending the half has to be a
-- request: this marks the guesses as spent and returns the finished board.
--
-- Safe to expose even though the browser decides when the clock has run out.
-- Calling it early only forfeits that player's own solve bonus - there is no
-- version of this call that pays out.
CREATE OR REPLACE FUNCTION public.quiz_phrase_give_up(
  p_attempt_id uuid, p_item_id uuid)
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
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency
    FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  SELECT * INTO v_att FROM public.quiz_attempts
   WHERE id = p_attempt_id AND team_member_id = v_member AND agency_id = v_agency
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'that game was not found, or it is not yours';
  END IF;
  IF NOT (COALESCE(v_att.context -> 'item_ids', '[]'::jsonb) ? p_item_id::text) THEN
    RAISE EXCEPTION 'that term is not part of this game';
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

  -- Already finished one way or the other: hand back what is already true
  -- rather than erroring, so a late clock tick cannot break the screen.
  IF NOT (v_solved OR v_misses >= 5) THEN
    v_misses := 5;
    UPDATE public.quiz_attempts
       SET context = COALESCE(context, '{}'::jsonb)
                     || jsonb_build_object('phrase_progress',
                          COALESCE(context -> 'phrase_progress', '{}'::jsonb)
                          || jsonb_build_object(p_item_id::text, jsonb_build_object(
                               'guessed', to_jsonb(v_guessed),
                               'misses',  v_misses,
                               'solved',  v_solved)))
     WHERE id = p_attempt_id;
  END IF;

  RETURN jsonb_build_object(
    'display', public.quiz_phrase_display(v_phrase, v_guessed, true),
    'guessed', to_jsonb(v_guessed),
    'misses',  v_misses,
    'solved',  v_solved,
    'over',    true,
    'answer',  v_phrase);
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_phrase_give_up(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_phrase_give_up(uuid, uuid) TO authenticated, service_role;