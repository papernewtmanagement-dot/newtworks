-- Tier-3 DRY: prefill_weekly_cpr_form now uses get_expected_teammates('compensation').
--
-- Original filter (compensation semantics, hand-rolled across the codebase):
--   category='agency' AND role_level<>'Owner' AND is_admin_backoffice=false
--   AND (archived_at IS NULL OR archived_at > v_week_start::timestamptz)
--
-- Canonical: get_expected_teammates(p_agency_id, 'compensation', v_week_start).
-- LEFT JOIN team only for hire_date (used in ORDER BY).

CREATE OR REPLACE FUNCTION public.prefill_weekly_cpr_form(p_agency_id UUID, p_week_ending_date DATE)
RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_report_id        uuid;
  v_inserted_details int := 0;
  v_existing_details int := 0;
  m                  record;
  v_week_start       date := p_week_ending_date - 6;
BEGIN
  SELECT id INTO v_report_id
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_ending_date;

  IF v_report_id IS NULL THEN
    INSERT INTO public.weekly_cpr_reports (agency_id, week_ending_date)
    VALUES (p_agency_id, p_week_ending_date)
    RETURNING id INTO v_report_id;
  END IF;

  FOR m IN
    SELECT et.team_id AS id
    FROM public.get_expected_teammates(p_agency_id, 'compensation', v_week_start) et
    JOIN public.team t ON t.id = et.team_id
    ORDER BY t.hire_date, et.last_name
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
$fn$;
