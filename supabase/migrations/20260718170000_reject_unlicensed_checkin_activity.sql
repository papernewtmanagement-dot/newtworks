-- Reject unlicensed team members reporting quotes or sales points on team_checkins.
-- Compliance floor: SF agent's agreement — unlicensed staff cannot quote, bind, or solicit
-- (core_principle #900 staff_liability). If quotes_week > 0 OR sales_points_quarter > 0 is
-- being newly claimed (INSERT, or UPDATE where the value changed), and the team member has
-- no active P&C, L&H, or IPS license, the write is rejected with LICENSE_REQUIRED.
-- License lookup is live against team.license_pc / license_lh / license_ips — new licensing
-- unlocks submissions automatically; no hardcoded exclusion list.

CREATE OR REPLACE FUNCTION public.reject_unlicensed_checkin_activity()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_first_name text;
  v_has_license boolean;
  v_quotes_new boolean := false;
  v_sp_new boolean := false;
  v_msg_parts text[] := '{}';
BEGIN
  IF COALESCE(NEW.quotes_week, 0) > 0
     AND (TG_OP = 'INSERT' OR OLD.quotes_week IS DISTINCT FROM NEW.quotes_week) THEN
    v_quotes_new := true;
  END IF;

  IF COALESCE(NEW.sales_points_quarter, 0) > 0
     AND (TG_OP = 'INSERT' OR OLD.sales_points_quarter IS DISTINCT FROM NEW.sales_points_quarter) THEN
    v_sp_new := true;
  END IF;

  IF NOT (v_quotes_new OR v_sp_new) THEN
    RETURN NEW;
  END IF;

  SELECT first_name,
         (COALESCE(license_pc,false) OR COALESCE(license_lh,false) OR COALESCE(license_ips,false))
  INTO v_first_name, v_has_license
  FROM public.team
  WHERE id = NEW.team_id;

  IF v_has_license IS TRUE THEN
    RETURN NEW;
  END IF;

  IF v_quotes_new THEN
    v_msg_parts := array_append(v_msg_parts, format('quotes=%s', NEW.quotes_week));
  END IF;
  IF v_sp_new THEN
    v_msg_parts := array_append(v_msg_parts, format('sales_points=%s', NEW.sales_points_quarter));
  END IF;

  RAISE EXCEPTION
    'LICENSE_REQUIRED: % has no active P&C, L&H, or IPS license — cannot report quotes or sales points. Rejected: %.',
    COALESCE(v_first_name, 'team member'), array_to_string(v_msg_parts, ', ')
  USING ERRCODE = 'check_violation';
END;
$$;

DROP TRIGGER IF EXISTS trg_reject_unlicensed_checkin_activity ON public.team_checkins;
CREATE TRIGGER trg_reject_unlicensed_checkin_activity
BEFORE INSERT OR UPDATE ON public.team_checkins
FOR EACH ROW
EXECUTE FUNCTION public.reject_unlicensed_checkin_activity();
