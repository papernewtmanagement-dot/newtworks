-- Peter 2026-08-28: pay projections are OWNER only, not owner+manager.
-- pay_projection_caller_ok previously accepted is_agency_admin(), which is
-- owner OR manager — so the one manager account could read the whole pay
-- ladder. Browser callers must now hold the owner role. Service-side and
-- direct database connections still pass (reseed and maintenance).
-- The Earning Potential tab is hidden from non-owners in the app as well;
-- this is the database half of the same rule.

CREATE OR REPLACE FUNCTION public.pay_projection_caller_ok()
RETURNS boolean
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
-- True when the caller may read pay projections: any service-side or direct
-- database connection, or a signed-in OWNER in the browser. Managers are
-- excluded on purpose.
DECLARE v_role text;
BEGIN
  BEGIN
    v_role := auth.role();
  EXCEPTION WHEN OTHERS THEN
    v_role := NULL;
  END;
  IF v_role IS NULL OR v_role NOT IN ('anon', 'authenticated') THEN
    RETURN true;   -- service role, cron, or a direct connection
  END IF;
  RETURN COALESCE(public.current_app_user_role() = 'owner', false);
END;
$function$;
