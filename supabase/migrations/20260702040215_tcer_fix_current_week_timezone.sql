
-- Fix: use CT (agency timezone) for current-week derivation, not UTC.
-- Otherwise Saturday 11pm CT submissions get rejected because UTC has ticked to Sunday.
CREATE OR REPLACE FUNCTION public.tcer_enforce_current_week() RETURNS TRIGGER AS $$
DECLARE
  today_ct DATE;
  week_start DATE;
  week_end DATE;
BEGIN
  IF TG_OP = 'INSERT' AND NEW.status = 'pending' THEN
    today_ct := (NOW() AT TIME ZONE 'America/Chicago')::date;
    week_start := today_ct - EXTRACT(DOW FROM today_ct)::INT;
    week_end := week_start + 6;
    IF NEW.punch_date < week_start OR NEW.punch_date > week_end THEN
      RAISE EXCEPTION 'Edit requests must be for the current agency week (% through %). Requested date: %', week_start, week_end, NEW.punch_date;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
