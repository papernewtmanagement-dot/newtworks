-- Logins cannot call require_login directly, so the bundle runs with owner rights like
-- cpr_recompute_on_open. It still checks the caller is staff first, and every function it
-- calls is either staff-checked itself or returns the same rows to every staff login.
ALTER FUNCTION public.get_cpr_page_bundle(uuid, date) SECURITY DEFINER;

