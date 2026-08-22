-- The three internal room helpers came out of the previous migration reachable
-- by any signed-in teammate. REVOKE ... FROM PUBLIC does not touch a grant made
-- to a named role, and this project's default privileges hand EXECUTE to
-- authenticated and service_role on every new function. So the revoke has to
-- name those roles.
--
-- Why it matters: _quiz_room_begin opens an attempt for every player and flips
-- a room into play, and _quiz_room_patch_state writes the mode's shared state
-- with no host check of its own - both are meant to be called only from inside
-- a per-mode start function that has already done its own checks.
--
-- STANDING: on this project, "REVOKE ALL FROM PUBLIC" is NOT enough to make a
-- function internal. Revoke from authenticated and anon by name as well, then
-- read pg_proc.proacl back to confirm only postgres and service_role remain.

REVOKE EXECUTE ON FUNCTION public._quiz_room_locked(uuid, boolean) FROM authenticated, anon;
REVOKE EXECUTE ON FUNCTION public._quiz_room_patch_state(uuid, jsonb) FROM authenticated, anon;
REVOKE EXECUTE ON FUNCTION public._quiz_room_begin(uuid, jsonb, jsonb) FROM authenticated, anon;

-- The public spine is correct as it stands, but pin anon off it explicitly so a
-- not-signed-in visitor cannot even reach the 'not signed in' exception.
REVOKE EXECUTE ON FUNCTION public.quiz_room_state(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.quiz_room_open(text, jsonb) FROM anon;
REVOKE EXECUTE ON FUNCTION public.quiz_room_list_open(text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.quiz_room_join(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.quiz_room_leave(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.quiz_room_abandon(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.quiz_room_my_finish(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.quiz_room_my_active(text) FROM anon;
