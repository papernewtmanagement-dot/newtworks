-- Trivia: drop the teammate read of the answer key.
--
-- Second half of the server-side reveal change. The first migration added the
-- functions (quiz_play_state, quiz_submit_answer, quiz_phrase_guess,
-- quiz_phrase_solve, quiz_phrase_give_up, quiz_play_availability) and the
-- frontend was switched over to them and confirmed live before this ran,
-- because these drops are what breaks the old browser reads.
--
-- After this, a teammate cannot read is_correct, explanation or phrase_answer
-- from any table. Agency admins keep their own select policies, which is what
-- the review and editing screens run on.

DROP POLICY IF EXISTS quiz_item_options_team_select ON public.quiz_item_options;
DROP POLICY IF EXISTS quiz_items_team_select ON public.quiz_items;

-- Direct inserts are gone too - every answer now goes through
-- quiz_submit_answer (or quiz_night_answer for the live host game), both of
-- which check that the question belongs to the game and that it has not already
-- been answered.
DROP POLICY IF EXISTS quiz_answers_own_insert ON public.quiz_answers;