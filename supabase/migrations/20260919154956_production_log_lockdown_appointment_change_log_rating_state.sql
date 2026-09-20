-- Production log lockdown (Peter 2026-09-19).
-- 1. appointment_log was the one production table the team could write to
--    straight from the browser. Every other production table is read-only and
--    all writes go through the rp_* functions, which check who you are and
--    whether the week is closed. Appointments now match.
-- 2. change_log rows can never be edited or removed by anyone, including a
--    future function running as the database owner.
-- 3. team_sales_points_rating_state was open to the whole internet. Only the
--    watcher function writes it, so nobody needs write access.

-- ---------------------------------------------------------------------
-- 1. appointment_log: read-only for signed-in staff
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS appointment_log_rw ON public.appointment_log;

DROP POLICY IF EXISTS appointment_log_auth_read ON public.appointment_log;
CREATE POLICY appointment_log_auth_read ON public.appointment_log
  FOR SELECT TO authenticated
  USING (agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid()));

REVOKE INSERT, UPDATE, DELETE ON public.appointment_log FROM authenticated, anon;

-- ---------------------------------------------------------------------
-- 2. change_log is append-only, full stop
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.change_log_is_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  RAISE EXCEPTION 'the change history cannot be edited or removed'
    USING ERRCODE = '42501';
END $fn$;

COMMENT ON FUNCTION public.change_log_is_append_only() IS
  'Peter 2026-09-19: the record of what changed is evidence. Nothing may rewrite it. Blocks UPDATE and DELETE on change_log for every caller, database owner included.';

DROP TRIGGER IF EXISTS trg_change_log_append_only ON public.change_log;
CREATE TRIGGER trg_change_log_append_only
  BEFORE UPDATE OR DELETE ON public.change_log
  FOR EACH ROW EXECUTE FUNCTION public.change_log_is_append_only();

REVOKE INSERT, UPDATE, DELETE ON public.change_log FROM authenticated, anon;

-- ---------------------------------------------------------------------
-- 3. team_sales_points_rating_state: nobody writes it from a browser
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS team_sales_points_rating_state_all ON public.team_sales_points_rating_state;

DROP POLICY IF EXISTS team_sales_points_rating_state_admin_read ON public.team_sales_points_rating_state;
CREATE POLICY team_sales_points_rating_state_admin_read ON public.team_sales_points_rating_state
  FOR SELECT TO authenticated
  USING (public.is_agency_admin());

REVOKE INSERT, UPDATE, DELETE ON public.team_sales_points_rating_state FROM authenticated, anon;
