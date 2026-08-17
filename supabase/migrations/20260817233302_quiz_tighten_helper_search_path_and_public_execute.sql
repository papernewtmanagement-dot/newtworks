-- Sweep of the same class of gap the server-side reveal work just closed, found
-- by running the security advisor straight after that change.
--
-- 1. The two new text helpers had no fixed search_path. They are only ever
--    called from functions that run as the table owner, so a caller-controlled
--    search_path is exactly the shape that gets abused - pin it, same as every
--    other function in this family already does.
--
-- 2. Five quiz functions were executable by the anonymous (not signed in) role,
--    because they were created without revoking the default grant that Postgres
--    hands to everyone. None of them leak anything today - each one resolves the
--    signed-in person first and stops with "not signed in" - but that is a
--    behaviour that happens to be safe rather than a rule, and two of the five
--    are trigger bodies that should never be reachable as a request at all.
--    Every other quiz function was already granted to the signed-in role only;
--    these five were the exceptions.

ALTER FUNCTION public.quiz_phrase_normalize(text) SET search_path TO 'public';
ALTER FUNCTION public.quiz_phrase_display(text, text[], boolean) SET search_path TO 'public';
ALTER FUNCTION public.quiz_items_require_valid_options() SET search_path TO 'public';

-- trigger bodies - not request surfaces
REVOKE ALL ON FUNCTION public.quiz_answers_night_write_guard() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_answers_night_write_guard() FROM authenticated;
REVOKE ALL ON FUNCTION public.quiz_items_require_valid_options() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.quiz_items_require_valid_options() FROM authenticated;

-- real request surfaces, signed-in only
REVOKE ALL ON FUNCTION public.quiz_mode_day_standings(text, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_mode_day_standings(text, date) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.quiz_report_block_item() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_report_block_item() TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.quiz_start_daily_attempt() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_start_daily_attempt() TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.quiz_start_duel_challenge(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_start_duel_challenge(uuid) TO authenticated, service_role;