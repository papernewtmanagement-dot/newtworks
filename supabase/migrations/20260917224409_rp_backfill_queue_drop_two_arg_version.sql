-- Adding the search parameter left the old two-argument rp_backfill_queue in
-- place beside the new one. Two functions of the same name make the REST layer
-- refuse the call as ambiguous, so the old one goes.
DROP FUNCTION IF EXISTS public.rp_backfill_queue(integer, integer);
