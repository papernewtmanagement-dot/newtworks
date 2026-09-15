-- CREATE OR REPLACE with an extra defaulted argument creates an OVERLOAD, it
-- does not replace. That left two functions and made the runner's two-argument
-- call ambiguous. One function per job: the two-argument twin goes.
DROP FUNCTION IF EXISTS public.check_ci_build_status(uuid, uuid);
