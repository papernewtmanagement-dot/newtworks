-- Spin & Solve full wheel mechanic (casino-wheel spin -> consonant value,
-- buy-a-vowel, Bankrupt, Lose a Turn, Free Spin) + wrong-guess limit fixed
-- to four everywhere, matching the original design ruling. Peter delegated
-- the four-vs-five call; four is what the scoring formula in
-- quiz_finish_attempt already assumed (GREATEST(0, 4 - LEAST(misses,4))),
-- so five was always the outlier, not four.

-- 1. Wheel config lives on the mode row, config-driven like every other mode.
ALTER TABLE public.quiz_modes ADD COLUMN IF NOT EXISTS wheel_segments jsonb;

UPDATE public.quiz_modes
   SET wheel_segments = '[
     {"type":"value","amount":40}, {"type":"value","amount":60},
     {"type":"value","amount":50}, {"type":"bankrupt"},
     {"type":"value","amount":70}, {"type":"value","amount":40},
     {"type":"value","amount":60}, {"type":"value","amount":80},
     {"type":"lose_turn"},         {"type":"value","amount":50},
     {"type":"value","amount":60}, {"type":"value","amount":40},
     {"type":"free_spin"},         {"type":"value","amount":70},
     {"type":"value","amount":50}, {"type":"value","amount":90},
     {"type":"bankrupt"},          {"type":"value","amount":40},
     {"type":"value","amount":60}, {"type":"value","amount":50},
     {"type":"value","amount":80}, {"type":"value","amount":40},
     {"type":"value","amount":60}, {"type":"value","amount":50}
   ]'::jsonb
 WHERE mode_key = 'spin_and_solve';

-- 2. quiz_answers needs somewhere to carry the banked wheel money from the
-- guessing half into quiz_finish_attempt's scoring pass, same pattern as the
-- existing phrase_solved / phrase_misses columns.
ALTER TABLE public.quiz_answers ADD COLUMN IF NOT EXISTS phrase_round_money int;

-- 3. Internal helper, not REST-exposed, mirrors _quiz_shared_grid_build_board's
-- convention: no grants, called only from owner-context SECURITY DEFINER fns.
CREATE OR REPLACE FUNCTION public._quiz_wheel_random_segment(p_segments jsonb, p_values_only boolean DEFAULT false)
RETURNS jsonb
LANGUAGE sql
SET search_path TO 'public'
AS $function$
  SELECT seg
    FROM jsonb_array_elements(p_segments) AS seg
   WHERE (NOT p_values_only) OR (seg->>'type' = 'value')
   ORDER BY random()
   LIMIT 1;
$function$;
REVOKE ALL ON FUNCTION public._quiz_wheel_random_segment(jsonb, boolean) FROM PUBLIC;

-- 4. Spin the wheel. Sets a pending spin value (or resolves Bankrupt / Lose a
-- Turn / Free Spin) on the item's phrase_progress. A consonant guess consumes
-- the pending value; a vowel purchase does not touch it.
CREATE OR REPLACE FUNCTION public.quiz_wheel_spin(p_attempt_id uuid, p_item_id uuid)
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
  v_segs    jsonb;
  v_prog    jsonb;
  v_guessed text[];
  v_misses  int;
  v_solved  boolean;
  v_money   int;
  v_pending jsonb;
  v_seg     jsonb;
  v_type    text;
  v_amount  int;
  v_free_spin_used boolean := false;
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

  SELECT wheel_segments INTO v_segs FROM public.quiz_modes
   WHERE agency_id = v_agency AND mode_key = v_att.mode_key;
  IF v_segs IS NULL OR jsonb_array_length(v_segs) = 0 THEN
    RAISE EXCEPTION 'this mode has no wheel configured';
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
  IF v_pending IS NOT NULL AND v_pending ->> 'type' = 'value' THEN
    RAISE EXCEPTION 'call a consonant with the spin you already have';
  END IF;

  v_seg  := public._quiz_wheel_random_segment(v_segs, false);
  v_type := v_seg ->> 'type';

  IF v_type = 'bankrupt' THEN
    v_money   := 0;
    v_pending := NULL;
  ELSIF v_type = 'lose_turn' THEN
    v_pending := NULL;
  ELSIF v_type = 'free_spin' THEN
    v_seg     := public._quiz_wheel_random_segment(v_segs, true);
    v_amount  := (v_seg ->> 'amount')::int;
    v_pending := jsonb_build_object('type', 'value', 'amount', v_amount);
    v_free_spin_used := true;
  ELSE
    v_amount  := (v_seg ->> 'amount')::int;
    v_pending := jsonb_build_object('type', 'value', 'amount', v_amount);
  END IF;

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
    'result_type',        v_type,
    'free_spin_resolved',  v_free_spin_used,
    'pending_spin',        v_pending,
    'round_money',         v_money,
    'misses',              v_misses,
    'guessed',             to_jsonb(v_guessed));
END; $function$;
REVOKE ALL ON FUNCTION public.quiz_wheel_spin(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_wheel_spin(uuid, uuid) TO authenticated, service_role;

-- 5. Buy a vowel. No spin required, fixed cost, no money earned or lost for
-- whether the vowel is present -- matches the source rule.
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
    'answer',  CASE WHEN v_over THEN v_phrase ELSE NULL END);
END; $function$;
REVOKE ALL ON FUNCTION public.quiz_wheel_buy_vowel(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_wheel_buy_vowel(uuid, uuid, text) TO authenticated, service_role;

-- 6. Consonant guessing now requires a pending spin value and pays that value
-- times the letter's occurrence count (the "multiple letter rule"). Vowels
-- are rejected here and pointed at quiz_wheel_buy_vowel. Miss threshold fixed
-- to four (was five).
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
    'answer',  CASE WHEN v_over THEN v_phrase ELSE NULL END);
END; $function$;

-- 7. Solve: threshold fixed to four, round_money now passed through for the
-- screen's running total (money itself is untouched by solving).
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
    v_misses := v_misses + 1;
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

-- 8. Give up: threshold fixed to four (was five). Round money is not zeroed
-- here -- it is simply never banked, because quiz_finish_attempt only pays
-- phrase_round_money when phrase_solved is true.
CREATE OR REPLACE FUNCTION public.quiz_phrase_give_up(p_attempt_id uuid, p_item_id uuid)
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
  v_money   := COALESCE((v_prog ->> 'round_money')::int, 0);

  IF NOT (v_solved OR v_misses >= 4) THEN
    v_misses := 4;
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
  END IF;

  RETURN jsonb_build_object(
    'display', public.quiz_phrase_display(v_phrase, v_guessed, true),
    'guessed', to_jsonb(v_guessed),
    'misses',  v_misses,
    'solved',  v_solved,
    'over',    true,
    'round_money', v_money,
    'answer',  v_phrase);
END; $function$;

-- 9. quiz_play_state: reveal threshold fixed to four; round_money +
-- pending_spin now travel with the phrase block so a refresh mid-spin resumes
-- correctly.
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
  v_money    int;
  v_pending  jsonb;
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
    v_was_ok := v_answered
                AND v_rec.chosen_option_id IS NOT NULL
                AND v_rec.chosen_option_id = v_correct;

    v_prog    := COALESCE(v_att.context -> 'phrase_progress' -> (v_rec.id::text), '{}'::jsonb);
    v_guessed := COALESCE(ARRAY(SELECT jsonb_array_elements_text(v_prog -> 'guessed')), ARRAY[]::text[]);
    v_misses  := COALESCE((v_prog ->> 'misses')::int, 0);
    v_solved  := COALESCE((v_prog ->> 'solved')::boolean, false);
    v_money   := COALESCE((v_prog ->> 'round_money')::int, 0);
    v_pending := v_prog -> 'pending_spin';
    v_over    := v_solved OR v_misses >= 4;
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
                       'round_money',  v_money,
                       'pending_spin', v_pending,
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

-- 10. quiz_submit_answer: clamp fixed to four, and now also carries the
-- banked round money forward into quiz_answers.phrase_round_money.
CREATE OR REPLACE FUNCTION public.quiz_submit_answer(p_attempt_id uuid, p_item_id uuid, p_chosen_option_id uuid DEFAULT NULL::uuid, p_seconds_taken numeric DEFAULT NULL::numeric)
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
  v_money   int := NULL;
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

  IF v_item.shape = 'phrase' THEN
    v_prog   := COALESCE(v_att.context -> 'phrase_progress' -> (p_item_id::text), '{}'::jsonb);
    v_solved := COALESCE((v_prog ->> 'solved')::boolean, false);
    v_misses := LEAST(GREATEST(COALESCE((v_prog ->> 'misses')::int, 4), 0), 4);
    v_money  := COALESCE((v_prog ->> 'round_money')::int, 0);
  END IF;

  INSERT INTO public.quiz_answers
    (attempt_id, item_id, chosen_option_id, seconds_taken, was_correct,
     phrase_solved, phrase_misses, phrase_round_money)
  VALUES (p_attempt_id, p_item_id, p_chosen_option_id,
          GREATEST(COALESCE(p_seconds_taken, 0), 0), v_was_ok,
          v_solved, v_misses, v_money);

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
    'phrase_misses',     v_misses,
    'phrase_round_money', v_money);
END; $function$;

-- 11. quiz_finish_attempt: bank the wheel money instead of the old flat
-- solve bonus. One-anchor patch, same discipline as the Grid points patch --
-- every other mode's scoring line is untouched.
CREATE OR REPLACE FUNCTION public.quiz_finish_attempt(p_attempt_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_att        public.quiz_attempts;
  v_mode       public.quiz_modes;
  v_agency     uuid;
  v_member     uuid;
  v_correct    int;
  v_total      int;
  v_points     int;
  v_passed     boolean := NULL;
  v_day        date;
  v_dow        int;
  v_week_start date;
  v_week_sat   date;
  v_week_pts   int := 0;
  v_label      text;
  v_on_board   boolean := false;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency
    FROM public.users u WHERE u.auth_user_id = auth.uid();

  SELECT * INTO v_att FROM public.quiz_attempts
   WHERE id = p_attempt_id AND team_member_id = v_member AND agency_id = v_agency
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'attempt not found or not yours'; END IF;

  SELECT * INTO v_mode FROM public.quiz_modes
   WHERE agency_id = v_agency AND mode_key = v_att.mode_key;

  IF v_att.finished_at IS NOT NULL THEN
    RETURN jsonb_build_object('already_finished', true,
      'correct_count', v_att.correct_count,
      'question_count', v_att.question_count,
      'points_earned', v_att.points_earned,
      'passed', v_att.passed,
      'passing_score', v_mode.passing_score);
  END IF;

  UPDATE public.quiz_answers a
     SET was_correct = EXISTS (SELECT 1 FROM public.quiz_item_options o
            WHERE o.id = a.chosen_option_id AND o.item_id = a.item_id AND o.is_correct),
         points = CASE WHEN COALESCE(a.phrase_solved, false)
            THEN COALESCE(a.phrase_round_money, 0)
            ELSE 0 END
 + CASE WHEN EXISTS (SELECT 1 FROM public.quiz_item_options o
            WHERE o.id = a.chosen_option_id AND o.item_id = a.item_id AND o.is_correct)
            THEN (COALESCE((SELECT (bp->>'points')::int
                    FROM jsonb_array_elements(v_att.context->'board_points') bp
                   WHERE (bp->>'item_id')::uuid = a.item_id LIMIT 1), 10)
 + CASE WHEN v_att.mode_key = 'trivia_night'
        THEN GREATEST(0, round(10.0
             * (COALESCE(v_mode.seconds_per_question, 20)
                - LEAST(COALESCE(a.seconds_taken, COALESCE(v_mode.seconds_per_question, 20)),
                        COALESCE(v_mode.seconds_per_question, 20)))::numeric
             / GREATEST(COALESCE(v_mode.seconds_per_question, 20), 1))::int)
        ELSE 0 END) ELSE 0 END
   WHERE a.attempt_id = p_attempt_id;

  SELECT COUNT(*), COUNT(*) FILTER (WHERE was_correct), COALESCE(SUM(points),0)
    INTO v_total, v_correct, v_points
    FROM public.quiz_answers WHERE attempt_id = p_attempt_id;

  IF COALESCE(v_mode.is_gating, false) AND v_mode.passing_score IS NOT NULL THEN
    v_passed := (v_total > 0
                 AND (v_correct * 100.0 / v_total) >= v_mode.passing_score);
  END IF;

  UPDATE public.quiz_items qi
     SET times_served  = qi.times_served + 1,
         times_correct = qi.times_correct + CASE WHEN a.was_correct THEN 1 ELSE 0 END,
         updated_at    = now()
    FROM public.quiz_answers a
   WHERE a.attempt_id = p_attempt_id AND qi.id = a.item_id AND qi.agency_id = v_agency;

  UPDATE public.quiz_attempts
     SET finished_at = now(), question_count = v_total,
         correct_count = v_correct, points_earned = v_points,
         score = v_points, passed = v_passed
   WHERE id = p_attempt_id;

  IF NOT COALESCE(v_mode.is_gating, false) THEN
    v_day        := v_att.attempt_day;
    v_dow        := EXTRACT(DOW FROM v_day)::int;
    v_week_start := v_day - v_dow;
    v_week_sat   := v_week_start + 6;
    v_label      := 'Trivia week of ' || to_char(v_week_sat, 'Mon DD, YYYY');

    SELECT COALESCE(SUM(qa.points_earned),0) INTO v_week_pts
      FROM public.quiz_attempts qa
      JOIN public.quiz_modes qm
        ON qm.agency_id = qa.agency_id AND qm.mode_key = qa.mode_key
     WHERE qa.agency_id = v_agency AND qa.team_member_id = v_member
       AND qa.finished_at IS NOT NULL
       AND qm.is_gating = false
       AND qa.attempt_day BETWEEN v_week_start AND v_week_sat;

    IF v_week_pts > 0 THEN
      DELETE FROM public.leaderboards
       WHERE agency_id = v_agency AND category = 'trivia_week_points'
         AND team_member_id = v_member AND record_period_label = v_label;

      WITH combined AS (
        SELECT team_member_id, record_value, record_period_label, set_at
          FROM public.leaderboards
         WHERE agency_id = v_agency AND category = 'trivia_week_points'
        UNION ALL
        SELECT v_member, v_week_pts::numeric, v_label, now()
      ),
      ranked AS (
        SELECT *, ROW_NUMBER() OVER (ORDER BY record_value DESC, set_at DESC) AS rn
          FROM combined
      ),
      wiped AS (
        DELETE FROM public.leaderboards
         WHERE agency_id = v_agency AND category = 'trivia_week_points'
        RETURNING 1
      )
      INSERT INTO public.leaderboards
        (agency_id, category, tier, team_member_id, record_value,
         record_period_label, record_week_ending, set_at)
      SELECT v_agency, 'trivia_week_points', rn, team_member_id, record_value,
             record_period_label, NULL, set_at
        FROM ranked WHERE rn <= 3 AND (SELECT COUNT(*) FROM wiped) >= 0;

      v_on_board := EXISTS (SELECT 1 FROM public.leaderboards
         WHERE agency_id = v_agency AND category = 'trivia_week_points'
           AND team_member_id = v_member AND record_period_label = v_label);
    END IF;
  END IF;

  RETURN jsonb_build_object('correct_count', v_correct, 'question_count', v_total,
    'points_earned', v_points, 'week_points', v_week_pts,
    'on_leaderboard', v_on_board, 'passed', v_passed,
    'passing_score', v_mode.passing_score);
END; $function$;
