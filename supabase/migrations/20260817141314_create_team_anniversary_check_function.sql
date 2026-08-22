CREATE OR REPLACE FUNCTION public.check_team_birthdays_anniversaries(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_rec record;
  v_anniv_lines text[] := ARRAY[]::text[];
  v_msg text;
  v_years int;
  v_next_date date;
  v_chat_id bigint := -5377408548;
  v_send_result jsonb;
BEGIN
  -- Work anniversaries only for now. team has no birth-date column anywhere
  -- in the schema (verified 2026-08-17) so birthdays cannot be checked until
  -- that data exists. See op-rule note logged same session.
  FOR v_rec IN
    SELECT first_name, hire_date
    FROM team
    WHERE agency_id = p_agency_id
      AND is_active = true
      AND hire_date IS NOT NULL
  LOOP
    v_next_date := make_date(EXTRACT(year FROM v_today)::int, EXTRACT(month FROM v_rec.hire_date)::int, EXTRACT(day FROM v_rec.hire_date)::int);
    IF v_next_date < v_today THEN
      v_next_date := v_next_date + interval '1 year';
    END IF;
    IF v_next_date BETWEEN v_today AND v_today + interval '28 days' THEN
      v_years := EXTRACT(year FROM v_next_date)::int - EXTRACT(year FROM v_rec.hire_date)::int;
      v_anniv_lines := array_append(
        v_anniv_lines,
        v_rec.first_name || ' — ' || v_years || ' year' || CASE WHEN v_years = 1 THEN '' ELSE 's' END || ' on ' || to_char(v_next_date, 'Mon DD')
      );
    END IF;
  END LOOP;

  IF array_length(v_anniv_lines, 1) IS NULL THEN
    RETURN jsonb_build_object('records_processed', 0, 'output_summary', 'No work anniversaries in the next 4 weeks.');
  END IF;

  v_msg := 'Work anniversaries coming up (next 4 weeks):' || chr(10) || array_to_string(v_anniv_lines, chr(10));

  v_send_result := public.telegram_send_message(v_chat_id, v_msg, NULL, NULL);

  RETURN jsonb_build_object(
    'records_processed', array_length(v_anniv_lines, 1),
    'output_summary', v_msg,
    'send_result', v_send_result
  );
END;
$function$;
