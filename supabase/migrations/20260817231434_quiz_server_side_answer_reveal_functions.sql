-- Trivia: move the answer reveal server-side and close the answer-key hole.
--
-- THE HOLE (confirmed live 2026-08-17): quiz_item_options_team_select let any
-- signed-in teammate read every option row of every approved item, is_correct
-- included, and quiz_items_team_select let them read explanation and
-- phrase_answer. Between those two policies the whole answer key was one
-- browser request away. That did not matter while the games were solo and
-- cosmetic. It matters now that all three solo modes carry a same-day team
-- scoreboard and points post to the weekly records board.
--
-- WHY THE FIX IS NOT "TIGHTEN THE POLICY": row-level rules cannot hide a
-- COLUMN, and column-level grants cannot tell an agency admin (who must see
-- is_correct to edit an item) from a teammate (who must not). So play data
-- stops being read from the tables at all and is served by these functions
-- instead - the same shape Trivia Night already used, where quiz_night_state
-- nulls out is_correct until the host flips the session to reveal.
--
-- FOUR PARTS:
--   1. quiz_play_state    - serves a game's questions with NO answer in them
--   2. quiz_submit_answer - records one answer and returns that one reveal
--   3. quiz_phrase_guess / quiz_phrase_solve - hidden-term guessing, server-side
--   4. the two team-read policies dropped, plus the direct-insert policy
--      (that part ships as a SECOND migration, after the frontend is live,
--      because those drops are what breaks the old browser reads)
--
-- Part 3 is not optional extra scope. The hidden-term board cannot be drawn
-- without the term, so if the browser keeps doing the letter guessing it needs
-- phrase_answer, and phrase_answer cannot be released. Progress therefore lives
-- in quiz_attempts.context->'phrase_progress' and the browser is told only
-- which blanks have been filled.

-- ── text helpers (owner-only; the definer functions below call them) ──

CREATE OR REPLACE FUNCTION public.quiz_phrase_normalize(p_text text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT btrim(regexp_replace(upper(COALESCE(p_text, '')), '\s+', ' ', 'g'));
$$;

-- The term as the player is allowed to see it: letters they have found stay,
-- letters they have not become an underscore, spaces / apostrophes / hyphens
-- always show so the shape of the term is visible. p_reveal true returns it
-- whole - used once the term is solved or the guesses have run out.
CREATE OR REPLACE FUNCTION public.quiz_phrase_display(
  p_phrase text, p_guessed text[], p_reveal boolean)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(string_agg(
           CASE
             WHEN t.ch !~ '[A-Z]'                              THEN t.ch
             WHEN p_reveal                                     THEN t.ch
             WHEN p_guessed IS NOT NULL AND t.ch = ANY(p_guessed) THEN t.ch
             ELSE '_'
           END, '' ORDER BY t.ord), '')
    FROM regexp_split_to_table(public.quiz_phrase_normalize(p_phrase), '')
         WITH ORDINALITY AS t(ch, ord);
$$;

REVOKE ALL ON FUNCTION public.quiz_phrase_normalize(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_phrase_display(text, text[], boolean) FROM PUBLIC;

-- ── 1. quiz_play_state ──
-- Everything a play screen needs for one attempt, and nothing it must not have.
-- Withheld until the matching answer row exists: which option is correct, the
-- explanation, and - for a hidden-term item - the term itself AND the stem,
-- because a hidden-term stem is the definition, which is the answer to the
-- second half of that game.
CREATE OR REPLACE FUNCTION public.quiz_play_state(p_attempt_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_member   uuid;
  v_agency   uuid;
  v_att      public.quiz_attempts;
  v_rec      record;
  v_items    jsonb := '[]'::jsonb;
  v_prog     jsonb;
  v_guessed  text[];
  v_misses   int;
  v_solved   boolean;
  v_over     boolean;
  v_answered boolean;
  v_correct  uuid;
  v_was_ok   boolean;
  v_show_term boolean;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency
    FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  SELECT * INTO v_att FROM public.quiz_attempts
   WHERE id = p_attempt_id AND team_member_id = v_member AND agency_id = v_agency;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'that game was not found, or it is not yours';
  END IF;

  FOR v_rec IN
    SELECT e.ord, qi.id, qi.shape, qi.stem, qi.category, qi.difficulty,
           qi.explanation, qi.phrase_answer,
           qa.id AS answer_id, qa.chosen_option_id
      FROM jsonb_array_elements_text(COALESCE(v_att.context -> 'item_ids', '[]'::jsonb))
           WITH ORDINALITY AS e(item_id, ord)
      JOIN public.quiz_items qi ON qi.id = e.item_id::uuid
      LEFT JOIN public.quiz_answers qa
        ON qa.attempt_id = p_attempt_id AND qa.item_id = qi.id
     ORDER BY e.ord
  LOOP
    v_answered := (v_rec.answer_id IS NOT NULL);

    SELECT o.id INTO v_correct
      FROM public.quiz_item_options o
     WHERE o.item_id = v_rec.id AND o.is_correct
     LIMIT 1;
    -- derived rather than read from quiz_answers.was_correct, which
    -- quiz_finish_attempt only fills in at the end of the game
    v_was_ok := v_answered
                AND v_rec.chosen_option_id IS NOT NULL
                AND v_rec.chosen_option_id = v_correct;

    v_prog    := COALESCE(v_att.context -> 'phrase_progress' -> (v_rec.id::text), '{}'::jsonb);
    v_guessed := COALESCE(ARRAY(SELECT jsonb_array_elements_text(v_prog -> 'guessed')), ARRAY[]::text[]);
    v_misses  := COALESCE((v_prog ->> 'misses')::int, 0);
    v_solved  := COALESCE((v_prog ->> 'solved')::boolean, false);
    v_over    := v_solved OR v_misses >= 5;
    v_show_term := (v_rec.shape = 'phrase') AND (v_over OR v_answered);

    v_items := v_items || jsonb_build_object(
      'item_id',    v_rec.id,
      'shape',      v_rec.shape,
      'category',   v_rec.category,
      'difficulty', v_rec.difficulty,
      'stem',       CASE WHEN v_rec.shape = 'phrase' AND NOT v_answered
                         THEN NULL ELSE v_rec.stem END,
      'answered',   v_answered,
      'chosen_option_id',  v_rec.chosen_option_id,
      'was_correct',       CASE WHEN v_answered THEN v_was_ok ELSE NULL END,
      'correct_option_id', CASE WHEN v_answered THEN v_correct ELSE NULL END,
      'explanation',       CASE WHEN v_answered THEN v_rec.explanation ELSE NULL END,
      'options', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                            'id', o.id, 'option_text', o.option_text,
                            'sort_order', o.sort_order) ORDER BY o.sort_order), '[]'::jsonb)
                    FROM public.quiz_item_options o WHERE o.item_id = v_rec.id),
      'phrase', CASE WHEN v_rec.shape = 'phrase' THEN jsonb_build_object(
                       'display', public.quiz_phrase_display(v_rec.phrase_answer, v_guessed, v_show_term),
                       'guessed', to_jsonb(v_guessed),
                       'misses',  v_misses,
                       'solved',  v_solved,
                       'over',    v_over,
                       'answer',  CASE WHEN v_show_term
                                       THEN public.quiz_phrase_normalize(v_rec.phrase_answer)
                                       ELSE NULL END)
                  ELSE NULL END
    );
  END LOOP;

  RETURN jsonb_build_object(
    'attempt_id', v_att.id,
    'mode_key',   v_att.mode_key,
    'finished',   (v_att.finished_at IS NOT NULL),
    'items',      v_items);
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_play_state(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_play_state(uuid) TO authenticated, service_role;

-- ── 2. quiz_submit_answer ──
-- Records one answer and hands back that one reveal. Replaces five direct
-- INSERTs into quiz_answers from the browser. The reveal is only ever returned
-- as the return value of the write that earns it, and the unique index added
-- below means the write happens once - so a player cannot read the answer and
-- then answer again.
CREATE OR REPLACE FUNCTION public.quiz_submit_answer(
  p_attempt_id       uuid,
  p_item_id          uuid,
  p_chosen_option_id uuid    DEFAULT NULL,
  p_seconds_taken    numeric DEFAULT NULL)
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
  v_correct uuid;
  v_was_ok  boolean;
  v_prog    jsonb;
  v_solved  boolean := NULL;
  v_misses  int := NULL;
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
  IF v_att.mode_key = 'trivia_night' THEN
    RAISE EXCEPTION 'trivia night answers go through the live game screen';
  END IF;
  IF v_att.finished_at IS NOT NULL THEN
    RAISE EXCEPTION 'that game is already finished';
  END IF;
  IF NOT (COALESCE(v_att.context -> 'item_ids', '[]'::jsonb) ? p_item_id::text) THEN
    RAISE EXCEPTION 'that question is not part of this game';
  END IF;
  IF EXISTS (SELECT 1 FROM public.quiz_answers
              WHERE attempt_id = p_attempt_id AND item_id = p_item_id) THEN
    RAISE EXCEPTION 'you already answered that one';
  END IF;

  SELECT * INTO v_item FROM public.quiz_items WHERE id = p_item_id;

  IF p_chosen_option_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.quiz_item_options o
        WHERE o.id = p_chosen_option_id AND o.item_id = p_item_id) THEN
    RAISE EXCEPTION 'that answer does not belong to this question';
  END IF;

  SELECT o.id INTO v_correct
    FROM public.quiz_item_options o
   WHERE o.item_id = p_item_id AND o.is_correct
   LIMIT 1;
  v_was_ok := (p_chosen_option_id IS NOT NULL AND p_chosen_option_id = v_correct);

  -- The hidden-term half is no longer reported by the browser. Solved-or-not
  -- and the miss count are read back off the server's own record of the
  -- guessing, so the solve bonus quiz_finish_attempt pays cannot be inflated.
  IF v_item.shape = 'phrase' THEN
    v_prog   := COALESCE(v_att.context -> 'phrase_progress' -> (p_item_id::text), '{}'::jsonb);
    v_solved := COALESCE((v_prog ->> 'solved')::boolean, false);
    v_misses := LEAST(GREATEST(COALESCE((v_prog ->> 'misses')::int, 5), 0), 5);
  END IF;

  INSERT INTO public.quiz_answers
    (attempt_id, item_id, chosen_option_id, seconds_taken, was_correct,
     phrase_solved, phrase_misses)
  VALUES (p_attempt_id, p_item_id, p_chosen_option_id,
          GREATEST(COALESCE(p_seconds_taken, 0), 0), v_was_ok,
          v_solved, v_misses);

  RETURN jsonb_build_object(
    'item_id',           p_item_id,
    'was_correct',       v_was_ok,
    'correct_option_id', v_correct,
    'explanation',       v_item.explanation,
    'stem',              v_item.stem,
    'phrase_answer',     CASE WHEN v_item.shape = 'phrase'
                              THEN public.quiz_phrase_normalize(v_item.phrase_answer)
                              ELSE NULL END,
    'phrase_solved',     v_solved,
    'phrase_misses',     v_misses);
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_submit_answer(uuid, uuid, uuid, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_submit_answer(uuid, uuid, uuid, numeric) TO authenticated, service_role;

-- ── 3. hidden-term guessing, server-side ──
-- Progress per term lives at quiz_attempts.context->'phrase_progress'-><item id>
-- as {guessed: [...], misses: n, solved: bool}. Five wrong guesses ends the
-- term, which is the rule the shipped screen already ran on.
CREATE OR REPLACE FUNCTION public.quiz_phrase_guess(
  p_attempt_id uuid, p_item_id uuid, p_letter text)
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
  v_hit     boolean;
  v_over    boolean;
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

  v_prog    := COALESCE(v_att.context -> 'phrase_progress' -> (p_item_id::text), '{}'::jsonb);
  v_guessed := COALESCE(ARRAY(SELECT jsonb_array_elements_text(v_prog -> 'guessed')), ARRAY[]::text[]);
  v_misses  := COALESCE((v_prog ->> 'misses')::int, 0);
  v_solved  := COALESCE((v_prog ->> 'solved')::boolean, false);

  IF v_solved OR v_misses >= 5 THEN
    RAISE EXCEPTION 'the term is already revealed';
  END IF;
  IF v_letter = ANY(v_guessed) THEN
    RAISE EXCEPTION 'you already tried that letter';
  END IF;

  v_guessed := v_guessed || v_letter;
  v_hit     := (position(v_letter IN v_phrase) > 0);
  IF NOT v_hit THEN v_misses := v_misses + 1; END IF;

  v_solved := NOT EXISTS (
    SELECT 1 FROM regexp_split_to_table(v_phrase, '') AS t(ch)
     WHERE t.ch ~ '[A-Z]' AND NOT (t.ch = ANY(v_guessed)));
  v_over := v_solved OR v_misses >= 5;

  UPDATE public.quiz_attempts
     SET context = COALESCE(context, '{}'::jsonb)
                   || jsonb_build_object('phrase_progress',
                        COALESCE(context -> 'phrase_progress', '{}'::jsonb)
                        || jsonb_build_object(p_item_id::text, jsonb_build_object(
                             'guessed', to_jsonb(v_guessed),
                             'misses',  v_misses,
                             'solved',  v_solved)))
   WHERE id = p_attempt_id;

  RETURN jsonb_build_object(
    'hit',     v_hit,
    'display', public.quiz_phrase_display(v_phrase, v_guessed, v_over),
    'guessed', to_jsonb(v_guessed),
    'misses',  v_misses,
    'solved',  v_solved,
    'over',    v_over,
    'answer',  CASE WHEN v_over THEN v_phrase ELSE NULL END);
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_phrase_guess(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_phrase_guess(uuid, uuid, text) TO authenticated, service_role;

-- Typing the whole term. Right answer fills the board; wrong answer costs a
-- guess, same as a wrong letter - which is what the shipped screen did.
CREATE OR REPLACE FUNCTION public.quiz_phrase_solve(
  p_attempt_id uuid, p_item_id uuid, p_text text)
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
  v_right   boolean;
  v_over    boolean;
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

  IF v_solved OR v_misses >= 5 THEN
    RAISE EXCEPTION 'the term is already revealed';
  END IF;

  v_right := (public.quiz_phrase_normalize(p_text) = v_phrase);
  IF v_right THEN
    v_solved  := true;
    v_guessed := ARRAY(SELECT DISTINCT t.ch
                         FROM regexp_split_to_table(v_phrase, '') AS t(ch)
                        WHERE t.ch ~ '[A-Z]');
  ELSE
    v_misses := v_misses + 1;
  END IF;
  v_over := v_solved OR v_misses >= 5;

  UPDATE public.quiz_attempts
     SET context = COALESCE(context, '{}'::jsonb)
                   || jsonb_build_object('phrase_progress',
                        COALESCE(context -> 'phrase_progress', '{}'::jsonb)
                        || jsonb_build_object(p_item_id::text, jsonb_build_object(
                             'guessed', to_jsonb(v_guessed),
                             'misses',  v_misses,
                             'solved',  v_solved)))
   WHERE id = p_attempt_id;

  RETURN jsonb_build_object(
    'correct', v_right,
    'display', public.quiz_phrase_display(v_phrase, v_guessed, v_over),
    'guessed', to_jsonb(v_guessed),
    'misses',  v_misses,
    'solved',  v_solved,
    'over',    v_over,
    'answer',  CASE WHEN v_over THEN v_phrase ELSE NULL END);
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_phrase_solve(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_phrase_solve(uuid, uuid, text) TO authenticated, service_role;

-- ── availability counts ──
-- The three lobby cards used to count the item table directly to decide whether
-- a mode had enough material. Those reads die with the team policy, and they
-- were wrong for an agency admin anyway: an admin's row rules are unfiltered,
-- so the admin's counts silently included draft and retired questions. Counted
-- here once, filtered the same way the start functions filter.
CREATE OR REPLACE FUNCTION public.quiz_play_availability()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_member uuid;
  v_agency uuid;
  v_shapes text[];
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency
    FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  SELECT COALESCE(array_agg(DISTINCT s), ARRAY['choice']::text[]) INTO v_shapes
    FROM public.quiz_modes m, unnest(COALESCE(m.allowed_shapes, ARRAY['choice']::text[])) AS s
   WHERE m.agency_id = v_agency AND m.mode_key IN ('daily_five', 'duel');
  IF v_shapes IS NULL OR array_length(v_shapes, 1) IS NULL THEN
    v_shapes := ARRAY['choice']::text[];
  END IF;

  RETURN jsonb_build_object(
    'pool_count', (SELECT COUNT(*) FROM public.quiz_items qi
                    WHERE qi.agency_id = v_agency AND qi.status = 'approved'
                      AND qi.report_blocked = false
                      AND COALESCE(qi.shape, 'choice') = ANY(v_shapes)),
    'phrase_count', (SELECT COUNT(*) FROM public.quiz_items qi
                      WHERE qi.agency_id = v_agency AND qi.status = 'approved'
                        AND qi.report_blocked = false AND qi.shape = 'phrase'
                        AND qi.phrase_answer IS NOT NULL),
    'grid_category_counts', COALESCE((
      SELECT jsonb_object_agg(x.category, x.n) FROM (
        SELECT qi.category, COUNT(*) AS n FROM public.quiz_items qi
         WHERE qi.agency_id = v_agency AND qi.status = 'approved'
           AND qi.report_blocked = false AND qi.shape = 'choice'
           AND qi.category IS NOT NULL
         GROUP BY qi.category) x), '{}'::jsonb));
END; $function$;

REVOKE ALL ON FUNCTION public.quiz_play_availability() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_play_availability() TO authenticated, service_role;

-- One answer row per question per game. This is what makes "reveal only after
-- the answer is recorded" safe: without it a player could record an answer,
-- read the reveal, and record a second, better one.
CREATE UNIQUE INDEX IF NOT EXISTS quiz_answers_one_per_item_per_attempt
  ON public.quiz_answers (attempt_id, item_id);