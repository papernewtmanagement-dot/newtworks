-- Advisory cleanup for the closed-day guard shipped minutes earlier.
-- 1. The trigger function had a role-mutable search_path. Pinned.
-- 2. closed_holiday_name was reachable by the authenticated role over
--    /rest/v1/rpc as a SECURITY DEFINER function. Nothing in the app calls it
--    directly, so EXECUTE is revoked from every client role. The trigger keeps
--    working because the trigger function is now SECURITY DEFINER itself and
--    runs as owner -- which also means a teammate who cannot see
--    company_holidays under row-level security can no longer slip a request
--    onto a closed day by being blind to the holiday.
CREATE OR REPLACE FUNCTION public.tg_tor_block_closed_day()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_holiday text;
BEGIN
  IF NEW.request_type IN ('standing_time_off_preference', 'four_day_off_change') THEN
    RETURN NEW;
  END IF;
  IF NEW.status IN ('denied', 'canceled', 'expired') THEN
    RETURN NEW;
  END IF;
  IF NEW.derived_from_holiday_id IS NOT NULL
     OR NEW.derived_from_standing_pref_id IS NOT NULL THEN
    RETURN NEW;
  END IF;
  IF NEW.start_date IS DISTINCT FROM NEW.end_date THEN
    RETURN NEW;
  END IF;

  v_holiday := public.closed_holiday_name(NEW.agency_id, NEW.start_date);
  IF v_holiday IS NULL THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'The office is closed on % for %. Everyone already has that day off, so time off cannot be filed for it. Pick another day.',
    to_char(NEW.start_date, 'FMDay, FMMonth FMDD'), v_holiday;
END $function$;

REVOKE EXECUTE ON FUNCTION public.closed_holiday_name(uuid, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.closed_holiday_name(uuid, date) FROM anon;
REVOKE EXECUTE ON FUNCTION public.closed_holiday_name(uuid, date) FROM PUBLIC;
