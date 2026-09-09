-- Peter ruling 2026-09-09: a teammate's FINAL week of employment is prorated by hours
-- worked out of 40, not by whole workdays employed out of 5.
--
-- Why: 29 CFR 541.602(b)(6) says an employer may pay a proportionate part of a salaried
-- (exempt) person's full salary for the time actually worked in the first and last week of
-- employment, and that paying the hourly or daily equivalent for time actually worked meets
-- the requirement. So the last week is the one week where hour-level proration is allowed
-- without touching the person's salaried classification. It is also the only way the pay
-- figure agrees with the hours figure on the same CPR page. Docking a partial day in any
-- OTHER week is still prohibited and would put the exemption at risk.
--
-- Scope: FINAL week only. The regulation permits the same treatment for a first week; that
-- was not asked for and is not applied here.
--
-- Paid time off counts as paid hours, so an approved paid day inside someone's last week is
-- still paid rather than silently dropped.
CREATE OR REPLACE FUNCTION public.team_week_base_fraction(
  p_agency_id  uuid,
  p_team_id    uuid,
  p_start_date date,
  p_end_date   date,
  p_week_end   date
) RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_hours numeric;
BEGIN
  -- Not the final week of employment: workdays employed / 5, unchanged behaviour.
  IF p_end_date IS NULL
     OR p_end_date < (p_week_end - 6)
     OR p_end_date > p_week_end THEN
    RETURN public.team_week_workday_fraction(p_start_date, p_end_date, p_week_end);
  END IF;

  -- Final week: hours worked plus paid time off, out of a 40-hour week.
  SELECT COALESCE(SUM(h.hours + h.paid_time_off_hours), 0)
    INTO v_hours
  FROM public.get_weekly_cpr_hours(p_agency_id, p_week_end) h
  WHERE h.team_member_id = p_team_id;

  RETURN LEAST(1.00, GREATEST(0, ROUND(v_hours / 40.0, 6)));
END
$function$;

COMMENT ON FUNCTION public.team_week_base_fraction(uuid, uuid, date, date, date) IS
  'Week fraction used to prorate design-rate base pay and the departure recapture. Final week of employment = hours worked plus paid time off / 40 (29 CFR 541.602(b)(6)); every other week = team_week_workday_fraction (workdays employed / 5). Both callers must use this one function or the freed base and the paid base stop adding up to the design base.';

GRANT EXECUTE ON FUNCTION public.team_week_base_fraction(uuid, uuid, date, date, date) TO authenticated, service_role;
