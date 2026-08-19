-- CRITICAL BUG FIX: quiz_phrase_guess and quiz_wheel_buy_vowel both cleared
-- pending_spin to NULL in the database UPDATE, but never included
-- 'pending_spin' in their RETURN jsonb. The frontend's applyProgress() treats
-- a missing key as "unchanged, keep the previous value" (by design, so a
-- response that doesn't touch a field doesn't wipe it) -- but these two
-- functions DO change it and just failed to say so. Net effect: after the
-- very first consonant guess, the client's local pending_spin state never
-- clears, so the Spin button stays permanently disabled ("Spun 60 — call a
-- consonant" forever) and the wheel can never be spun again.

CREATE OR REPLACE FUNCTION public.quiz_phrase_guess(p_attempt_id uuid, p_item_id uuid, p_letter text)
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
  v_letter  text;
  v_prog    jsonb;
  v_guessed text[];
  v_misses  int;
  v_solved  boolean;
  v_money   int;
  v_pending jsonb;
  v_amount  int;
  v_hit     boolean;
  v_over    boolean;
  v_occurrences int;
  v_earned  int := 0;
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

  v_letter := upper(btrim(COALESCE(p_letter, '')));
  IF v_letter !~ '^[A-Z]$' THEN
    RAISE EXCEPTION 'pick a single letter';
  END IF;
  IF v_letter ~ '^[AEIOU]$' THEN
    RAISE EXCEPTION 'vowels are bought, not spun - use buy a vowel';
  END IF;

  v_prog    := COALESCE(v_att.context -> 'phrase_progress' -> (p_item_id::text), '{}'::jsonb);
  v_guessed := COALESCE(ARRAY(SELECT jsonb_array_elements_text(v_prog -> 'guessed')), ARRAY[]::text[]);
  v_misses  := COALESCE((v_prog ->> 'misses')::int, 0);
  v_solved  := COALESCE((v_prog ->> 'solved')::boolean, false);
  v_money   := COALESCE((v_prog ->> 'round_money')::int, 0);
  v_pending := v_prog -> 'pending_spin';

  IF v_solved OR v_misses >= 4 THEN
    RAISE EXCEPTION 'the term is already revealed';
  END IF;
  IF v_letter = ANY(v_guessed) THEN
    RAISE EXCEPTION 'you already tried that letter';
  END IF;
  IF v_pending IS NULL OR v_pending ->> 'type' <> 'value' THEN
    RAISE EXCEPTION 'spin the wheel before calling a consonant';
  END IF;
  v_amount := (v_pending ->> 'amount')::int;

  v_guessed     := v_guessed || v_letter;
  v_occurrences := length(v_phrase) - length(replace(v_phrase, v_letter, ''));
  v_hit         := (v_occurrences > 0);

  IF v_hit THEN
    v_earned := v_amount * v_occurrences;
    v_money  := v_money + v_earned;
  ELSE
    v_misses := v_misses + 1;
  END IF;

  v_solved := NOT EXISTS (
    SELECT 1 FROM regexp_split_to_table(v_phrase, '') AS t(ch)
     WHERE t.ch ~ '[A-Z]' AND NOT (t.ch = ANY(v_guessed)));
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
                             'pending_spin', NULL)))
   WHERE id = p_attempt_id;

  RETURN jsonb_build_object(
    'hit',     v_hit,
    'earned',  v_earned,
    'display', public.quiz_phrase_display(v_phrase, v_guessed, v_over),
    'guessed', to_jsonb(v_guessed),
    'misses',  v_misses,
    'solved',  v_solved,
    'over',    v_over,
    'round_money', v_money,
    'pending_spin', NULL,
    'answer',  CASE WHEN v_over THEN v_phrase ELSE NULL END);
END; $function$;

CREATE OR REPLACE FUNCTION public.quiz_wheel_buy_vowel(p_attempt_id uuid, p_item_id uuid, p_letter text)
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
  v_letter  text;
  v_prog    jsonb;
  v_guessed text[];
  v_misses  int;
  v_solved  boolean;
  v_money   int;
  v_over    boolean;
  v_cost    CONSTANT int := 25;
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

  v_letter := upper(btrim(COALESCE(p_letter, '')));
  IF v_letter !~ '^[AEIOU]$' THEN
    RAISE EXCEPTION 'that is not a vowel - spin the wheel for a consonant instead';
  END IF;

  v_prog    := COALESCE(v_att.context -> 'phrase_progress' -> (p_item_id::text), '{}'::jsonb);
  v_guessed := COALESCE(ARRAY(SELECT jsonb_array_elements_text(v_prog -> 'guessed')), ARRAY[]::text[]);
  v_misses  := COALESCE((v_prog ->> 'misses')::int, 0);
  v_solved  := COALESCE((v_prog ->> 'solved')::boolean, false);
  v_money   := COALESCE((v_prog ->> 'round_money')::int, 0);

  IF v_solved OR v_misses >= 4 THEN
    RAISE EXCEPTION 'the term is already revealed';
  END IF;
  IF v_letter = ANY(v_guessed) THEN
    RAISE EXCEPTION 'you already tried that letter';
  END IF;
  IF v_money < v_cost THEN
    RAISE EXCEPTION 'not enough on the board yet - a vowel costs % points', v_cost;
  END IF;

  v_money   := v_money - v_cost;
  v_guessed := v_guessed || v_letter;

  v_solved := NOT EXISTS (
    SELECT 1 FROM regexp_split_to_table(v_phrase, '') AS t(ch)
     WHERE t.ch ~ '[A-Z]' AND NOT (t.ch = ANY(v_guessed)));
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
                             'pending_spin', NULL)))
   WHERE id = p_attempt_id;

  RETURN jsonb_build_object(
    'display', public.quiz_phrase_display(v_phrase, v_guessed, v_over),
    'guessed', to_jsonb(v_guessed),
    'misses',  v_misses,
    'solved',  v_solved,
    'over',    v_over,
    'round_money', v_money,
    'pending_spin', NULL,
    'answer',  CASE WHEN v_over THEN v_phrase ELSE NULL END);
END; $function$;

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
  v_pending jsonb;
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
  v_pending := v_prog -> 'pending_spin';

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
                             'pending_spin', v_pending)))
   WHERE id = p_attempt_id;

  RETURN jsonb_build_object(
    'correct', v_right,
    'display', public.quiz_phrase_display(v_phrase, v_guessed, v_over),
    'guessed', to_jsonb(v_guessed),
    'misses',  v_misses,
    'solved',  v_solved,
    'over',    v_over,
    'round_money', v_money,
    'pending_spin', v_pending,
    'answer',  CASE WHEN v_over THEN v_phrase ELSE NULL END);
END; $function$;
