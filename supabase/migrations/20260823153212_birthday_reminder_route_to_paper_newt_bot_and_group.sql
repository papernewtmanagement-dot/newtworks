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
  v_bday_lines text[] := ARRAY[]::text[];
  v_msg text;
  v_years int;
  v_next_date date;
  v_chat_id bigint;
  v_send_result jsonb;
  v_total int;
BEGIN
  -- Route: Paper Newt Management group, sent by paper_newt_bot.
  SELECT setting_value::bigint INTO v_chat_id
  FROM public.settings
  WHERE agency_id = p_agency_id
    AND setting_key = 'paper_newt_management_group_chat_id';
  v_chat_id := COALESCE(v_chat_id, -5518666399);

  -- Work anniversaries, from hire_date
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

  -- Birthdays, from date_of_birth
  FOR v_rec IN
    SELECT first_name, date_of_birth
    FROM team
    WHERE agency_id = p_agency_id
      AND is_active = true
      AND date_of_birth IS NOT NULL
  LOOP
    v_next_date := make_date(EXTRACT(year FROM v_today)::int, EXTRACT(month FROM v_rec.date_of_birth)::int, EXTRACT(day FROM v_rec.date_of_birth)::int);
    IF v_next_date < v_today THEN
      v_next_date := v_next_date + interval '1 year';
    END IF;
    IF v_next_date BETWEEN v_today AND v_today + interval '28 days' THEN
      v_bday_lines := array_append(
        v_bday_lines,
        v_rec.first_name || ' — ' || to_char(v_next_date, 'Mon DD')
      );
    END IF;
  END LOOP;

  v_total := COALESCE(array_length(v_anniv_lines, 1), 0) + COALESCE(array_length(v_bday_lines, 1), 0);

  IF v_total = 0 THEN
    RETURN jsonb_build_object('records_processed', 0, 'output_summary', 'No birthdays or work anniversaries in the next 4 weeks.');
  END IF;

  v_msg := 'Coming up in the next 4 weeks:';
  IF array_length(v_bday_lines, 1) IS NOT NULL THEN
    v_msg := v_msg || chr(10) || chr(10) || 'Birthdays:' || chr(10) || array_to_string(v_bday_lines, chr(10));
  END IF;
  IF array_length(v_anniv_lines, 1) IS NOT NULL THEN
    v_msg := v_msg || chr(10) || chr(10) || 'Work anniversaries:' || chr(10) || array_to_string(v_anniv_lines, chr(10));
  END IF;

  v_send_result := public.paper_newt_send_message(v_chat_id, v_msg, NULL, NULL);

  RETURN jsonb_build_object(
    'records_processed', v_total,
    'output_summary', v_msg,
    'send_result', v_send_result
  );
END;
$function$;
