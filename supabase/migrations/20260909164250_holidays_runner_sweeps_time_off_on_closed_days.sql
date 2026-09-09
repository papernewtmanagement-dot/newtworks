CREATE OR REPLACE FUNCTION public.seed_company_holidays_runner(p_agency_id uuid, p_recipe_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_year int := EXTRACT(year FROM (now() AT TIME ZONE 'America/Chicago'))::int;
  v_this jsonb;
  v_next jsonb;
  v_off  jsonb;
  v_void jsonb;
  v_total int;
BEGIN
  v_this := public.seed_company_holidays(p_agency_id, v_year);
  v_next := public.seed_company_holidays(p_agency_id, v_year + 1);
  v_off  := public.materialize_holiday_time_off_for_team(p_agency_id);
  -- Peter ruling 2026-09-09: a closure voids all other time off that day.
  -- The trigger blocks new filings; this catches anything already sitting on
  -- a closed day, including rows that only became collisions when a holiday
  -- date shifted in the seed above.
  v_void := public.void_time_off_on_closed_days(p_agency_id);

  v_total := (v_this->>'inserted')::int + (v_this->>'updated')::int
           + (v_next->>'inserted')::int + (v_next->>'updated')::int
           + (v_off->>'created')::int
           + (v_void->>'canceled')::int;

  RETURN jsonb_build_object(
    'records_processed', v_total,
    'output_summary', format(
      'Holidays: %s new / %s refreshed for %s, %s new / %s refreshed for %s. Office-closed days off: %s created, %s already existed. Time off canceled on closed days: %s.',
      v_this->>'inserted', v_this->>'updated', v_year,
      v_next->>'inserted', v_next->>'updated', v_year + 1,
      v_off->>'created', v_off->>'skipped_existing',
      v_void->>'canceled'),
    'this_year', v_this,
    'next_year', v_next,
    'office_closed_days_off', v_off,
    'time_off_voided_on_closed_days', v_void
  );
END $function$;
