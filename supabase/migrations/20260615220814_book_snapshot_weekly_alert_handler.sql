-- Internal handler for "Weekly Book Snapshot - Manual Entry Alert" recipe.
-- Runs Saturday morning. Computes the most-recent-Saturday date, checks whether a weekly
-- book_snapshot row exists for that date, and creates a single open alert (idempotent) that
-- routes to the Financials > Book of Business module. Severity stays 'info' if the parse
-- already landed; bumps to 'warning' if no row exists yet (so Peter sees both branches at a glance).

CREATE OR REPLACE FUNCTION public.book_snapshot_weekly_alert(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_today          DATE := CURRENT_DATE;
  v_target_sat     DATE;
  v_existing       public.book_snapshot%ROWTYPE;
  v_mod_ref        TEXT;
  v_already_open   INTEGER;
  v_title          TEXT;
  v_message        TEXT;
  v_severity       TEXT;
  v_alert_count    INTEGER := 0;
BEGIN
  -- Most recent Saturday on or before today (DOW 6 = Saturday in Postgres EXTRACT(DOW))
  v_target_sat := v_today - ((EXTRACT(DOW FROM v_today)::int + 1) % 7);

  v_mod_ref := 'book_snapshot_weekly_alert:' || v_target_sat::text;

  -- Already an open alert for this Saturday? Bail.
  SELECT COUNT(*) INTO v_already_open
  FROM public.alerts
  WHERE agency_id = p_agency_id
    AND module_reference = v_mod_ref
    AND COALESCE(is_resolved, false) = false;

  IF v_already_open > 0 THEN
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary',    'Alert already open for ' || v_target_sat::text || '; skipped.'
    );
  END IF;

  -- Look for the weekly book_snapshot row for this Saturday
  SELECT * INTO v_existing
  FROM public.book_snapshot
  WHERE agency_id = p_agency_id
    AND snapshot_date = v_target_sat
    AND cadence = 'weekly'
  LIMIT 1;

  IF FOUND THEN
    v_title    := 'Confirm this week''s book snapshot (' || to_char(v_target_sat, 'Mon DD') || ')';
    v_message  := 'Auto-import from the SF CRM Analytics email landed. Open Financials > Book of Business > Add snapshot manually to review and fill in Health, MTD production/lapse, DSS/MLD, and LOB-per-HH counts. The form will pre-fill with the parsed values.';
    v_severity := 'info';
  ELSE
    v_title    := 'Enter this week''s book snapshot (' || to_char(v_target_sat, 'Mon DD') || ')';
    v_message  := 'No row found for ' || to_char(v_target_sat, 'Mon DD, YYYY') || ' yet. Either the SF CRM Analytics email did not arrive / parse, or it has not been forwarded. Open Financials > Book of Business > Add snapshot manually to enter this week''s numbers.';
    v_severity := 'warning';
  END IF;

  INSERT INTO public.alerts (
    agency_id, alert_type, severity, title, message,
    module_reference, is_read, is_resolved, due_date, created_at
  ) VALUES (
    p_agency_id, 'book_snapshot_weekly', v_severity, v_title, v_message,
    v_mod_ref, false, false, v_target_sat, NOW()
  );

  v_alert_count := 1;

  RETURN jsonb_build_object(
    'records_processed', v_alert_count,
    'output_summary',    'Alert created for week ending ' || v_target_sat::text || ' (' || v_severity || ').'
  );
END;
$$;

-- Grants follow the same convention as other internal_handler functions
GRANT EXECUTE ON FUNCTION public.book_snapshot_weekly_alert(uuid, uuid) TO anon, authenticated, service_role;
