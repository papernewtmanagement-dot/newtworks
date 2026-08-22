-- Same-class sweep after the room-spine grant fix. The two existing trivia
-- helpers are documented as internal with no grants, and they are not: this
-- project's default privileges hand EXECUTE to authenticated on every new
-- function, and the original migrations only revoked from PUBLIC.
--
-- Neither leaks anything today. _quiz_shared_grid_build_board returns item ids
-- and point values with no answer key, and neither helper is SECURITY DEFINER,
-- so a non-admin caller reads zero rows off quiz_items and hits its own
-- exception. Both are called from SECURITY DEFINER functions running as owner,
-- so removing the grant changes nothing about how the games work.
--
-- Fixing anyway: a helper documented as unreachable that is in fact reachable
-- is a landmine for whoever reads the documentation and trusts it.

REVOKE EXECUTE ON FUNCTION public._quiz_shared_grid_build_board(uuid, integer) FROM authenticated, anon;
REVOKE EXECUTE ON FUNCTION public._quiz_wheel_random_segment(jsonb, boolean) FROM authenticated, anon;
