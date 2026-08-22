-- Rewritten to match the new data model:
--   - Team checklist booleans now live on weekly_cpr_reports (not detail). Defaults to true on report INSERT.
--   - Hours/location no longer stored; computed at runtime via get_weekly_cpr_hours.
--   - Requirements columns carryover/missed/cost/total are computed at runtime via get_weekly_cpr_requirements.
--     The detail row only stores: code_reds, code_yellows, cpr_reply_done, wrapup_done, inbox_done,
--     quotes_discussed, sales_points, paid, owed, and pay components.
--   - We still ensure rows exist for each active non-Owner agency teammate.
--   - Carryover from prior week's owed is no longer copied into a detail column; the runtime function reads
--     it directly. So this prefill just ensures the report + detail rows are present.
CREATE OR REPLACE FUNCTION public.prefill_weekly_cpr_form(
  p_agency_id        uuid,
  p_week_ending_date date
)
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
BEGIN
  -- 1) Ensure the report row exists; create with team checklist booleans defaulting true.
  SELECT id INTO v_report_id
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_ending_date;

  IF v_report_id IS NULL THEN
    INSERT INTO public.weekly_cpr_reports (
      agency_id, week_ending_date,
      shareds_done, texts_done, deposits_done, appts_done, tasks_done, cases_done,
      no_fu_task_done, new_opps_done, no_onboarding_done, no_phone_done, bad_data_done
    )
    VALUES (
      p_agency_id, p_week_ending_date,
      true, true, true, true, true, true,
      true, true, true, true, true
    )
    RETURNING id INTO v_report_id;
  END IF;

  -- 2) Ensure detail row exists for each active non-Owner agency teammate.
  FOR m IN
    SELECT t.id
    FROM public.team t
    WHERE t.agency_id   = p_agency_id
      AND t.category    = 'agency'
      AND t.is_active   = true
      AND t.archived_at IS NULL
      AND COALESCE(t.role_level, '') <> 'Owner'
    ORDER BY t.hire_date, t.last_name
  LOOP
    INSERT INTO public.weekly_cpr_team_detail (
      agency_id, weekly_cpr_report_id, team_member_id,
      cpr_reply_done, wrapup_done, inbox_done,
      paid, owed
    )
    VALUES (
      p_agency_id, v_report_id, m.id,
      true, true, true,
      0, 0
    )
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
    'note',              'Carryover, missed, cost, total, net_quotes, hours, location are computed at runtime — not stored.'
  );
END;
$function$;
