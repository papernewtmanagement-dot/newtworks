-- prefill_weekly_cpr_form: stop hardcoding true on checklist booleans.
-- New weeks should load with checklist items UNCHECKED (NULL) until
-- explicitly marked. Matches the standing rule that absent data isn't
-- a "hit" — it's "no data yet."
CREATE OR REPLACE FUNCTION public.prefill_weekly_cpr_form(p_agency_id uuid, p_week_ending_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_report_id        uuid;
  v_inserted_details int := 0;
  v_existing_details int := 0;
  m                  record;
  v_week_start       date := p_week_ending_date - 6;
BEGIN
  -- 1) Ensure the report row exists. Team checklist booleans are LEFT NULL
  --    so the UI loads unchecked until explicitly marked.
  SELECT id INTO v_report_id
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_ending_date;

  IF v_report_id IS NULL THEN
    INSERT INTO public.weekly_cpr_reports (agency_id, week_ending_date)
    VALUES (p_agency_id, p_week_ending_date)
    RETURNING id INTO v_report_id;
  END IF;

  -- 2) Ensure detail row exists for each teammate who was on the team
  --    Sunday morning of this week. Snapshot policy — see operational_rule
  --    "CPR snapshot policy — team membership at week start".
  --    Personal checklist booleans left NULL.
  FOR m IN
    SELECT t.id
    FROM public.team t
    WHERE t.agency_id   = p_agency_id
      AND t.category    = 'agency'
      AND COALESCE(t.role_level, '') <> 'Owner'
      AND (t.archived_at IS NULL OR t.archived_at > v_week_start::timestamptz)
    ORDER BY t.hire_date, t.last_name
  LOOP
    INSERT INTO public.weekly_cpr_team_detail (
      agency_id, weekly_cpr_report_id, team_member_id
    )
    VALUES (p_agency_id, v_report_id, m.id)
    ON CONFLICT (weekly_cpr_report_id, team_member_id) DO NOTHING;

    IF FOUND THEN
      v_inserted_details := v_inserted_details + 1;
    ELSE
      v_existing_details := v_existing_details + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'report_id',         v_report_id,
    'inserted_details',  v_inserted_details,
    'existing_details',  v_existing_details,
    'note',              'Checklist booleans, carryover, missed, cost, total, hours computed at runtime — not stored. Booleans default NULL = unchecked until marked.'
  );
END;
$function$;
