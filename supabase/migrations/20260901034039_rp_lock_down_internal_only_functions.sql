-- Postgres grants EXECUTE to PUBLIC on every new function by default, and
-- PostgREST turns that into a callable endpoint for the anon role. Three of the
-- functions added earlier today take an agency id as an argument and then just
-- do the work with no caller check, so anyone could have written quote counts
-- into the weekly report or fired alerts. The two trigger functions never need
-- to be callable at all. Locking those five down.
--
-- Note: this is the same warning that already sits on the older rp_* functions
-- (rp_log_quote, rp_log_sale, rp_log_activity, rp_void_quote and others, 34 in
-- all). Those check the caller through rp_resolve_actor, so they are far less
-- exposed, and re-permissioning the whole database is not part of this work.

REVOKE ALL ON FUNCTION public.rp_sync_quotes_to_cpr_detail(uuid, uuid, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rp_resync_quotes_week(uuid, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.run_rp_save_clear_reminder(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.quote_log_sync_to_cpr_detail() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cancellation_log_void_unpaid_saves() FROM PUBLIC, anon, authenticated;

-- These two are the team-facing entry points and must stay callable by a
-- signed-in teammate. Both resolve the actor server-side via rp_resolve_actor,
-- which refuses anyone without a session.
REVOKE ALL ON FUNCTION public.rp_log_cancellation(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_log_cancellation(jsonb) TO authenticated;

REVOKE ALL ON FUNCTION public.rp_void_cancellation(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_void_cancellation(uuid, text) TO authenticated;

-- Read-only boolean, but there is no reason for a signed-out caller to have it.
REVOKE ALL ON FUNCTION public.rp_program_live(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_program_live(uuid, date) TO authenticated;
