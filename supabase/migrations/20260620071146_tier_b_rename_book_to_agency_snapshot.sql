BEGIN;

-- (1) Create the new function with identical body but renamed identifier.
CREATE OR REPLACE FUNCTION public.agency_snapshot_weekly_alert(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_today          DATE := CURRENT_DATE;
  v_target_sat     DATE;
  v_existing       public.agency_snapshot%ROWTYPE;
  v_mod_ref        TEXT;
  v_already_open   INTEGER;
  v_title          TEXT;
  v_message        TEXT;
  v_severity       TEXT;
  v_alert_count    INTEGER := 0;
BEGIN
  v_target_sat := v_today - ((EXTRACT(DOW FROM v_today)::int + 1) % 7);
  v_mod_ref := 'agency_snapshot_weekly_alert:' || v_target_sat::text;

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

  SELECT * INTO v_existing
  FROM public.agency_snapshot
  WHERE agency_id = p_agency_id
    AND snapshot_date = v_target_sat
    AND cadence = 'weekly'
  LIMIT 1;

  IF FOUND THEN
    v_title    := 'Confirm this week''s agency snapshot (' || to_char(v_target_sat, 'Mon DD') || ')';
    v_message  := 'Auto-import from the SF CRM Analytics email landed. Open Financials > Book of Business > Add snapshot manually to review and fill in YTD new/lost counts, life paid_for count + premium, and IPS new money. The form will pre-fill with the parsed stock values.';
    v_severity := 'info';
  ELSE
    v_title    := 'Enter this week''s agency snapshot (' || to_char(v_target_sat, 'Mon DD') || ')';
    v_message  := 'No row found for ' || to_char(v_target_sat, 'Mon DD, YYYY') || ' yet. Either the SF CRM Analytics email did not arrive / parse, or it has not been forwarded. Open Financials > Book of Business > Add snapshot manually to enter this week''s numbers.';
    v_severity := 'warning';
  END IF;

  INSERT INTO public.alerts (
    agency_id, alert_type, severity, title, message,
    module_reference, is_read, is_resolved, due_date, created_at
  ) VALUES (
    p_agency_id, 'agency_snapshot_weekly', v_severity, v_title, v_message,
    v_mod_ref, false, false, v_target_sat, NOW()
  );

  v_alert_count := 1;

  RETURN jsonb_build_object(
    'records_processed', v_alert_count,
    'output_summary',    'Alert created for week ending ' || v_target_sat::text || ' (' || v_severity || ').'
  );
END;
$function$;

-- (2) Repoint the recipe's internal_handler to the new function before dropping the old one.
UPDATE public.automation_recipes
SET internal_handler = 'agency_snapshot_weekly_alert'
WHERE internal_handler = 'book_snapshot_weekly_alert';

-- (3) Rename the two recipes
UPDATE public.automation_recipes
SET recipe_name = 'Weekly Agency Snapshot - Gmail Parse'
WHERE recipe_name = 'Weekly Book Snapshot - Gmail Parse';

UPDATE public.automation_recipes
SET recipe_name = 'Weekly Agency Snapshot - Manual Entry Alert'
WHERE recipe_name = 'Weekly Book Snapshot - Manual Entry Alert';

-- (4) Update existing alerts row(s) to use the new module_reference prefix
UPDATE public.alerts
SET module_reference = replace(module_reference, 'book_snapshot_weekly_alert:', 'agency_snapshot_weekly_alert:'),
    alert_type       = CASE WHEN alert_type = 'book_snapshot_weekly' THEN 'agency_snapshot_weekly' ELSE alert_type END
WHERE module_reference LIKE 'book_snapshot_weekly_alert:%';

-- (5) Drop the old function (no callers remain — verified before this migration)
DROP FUNCTION public.book_snapshot_weekly_alert(uuid, uuid);

-- (6) Update persistent_memory references to the renamed recipes + function name
UPDATE public.persistent_memory
SET content =
  replace(
    replace(
      replace(
        replace(content,
          'Weekly Book Snapshot - Gmail Parse', 'Weekly Agency Snapshot - Gmail Parse'),
        'Weekly Book Snapshot — Gmail Parse', 'Weekly Agency Snapshot — Gmail Parse'),
      'Weekly Book Snapshot - Manual Entry Alert', 'Weekly Agency Snapshot - Manual Entry Alert'),
    'Weekly Book Snapshot — Manual Entry Alert', 'Weekly Agency Snapshot — Manual Entry Alert'),
  updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND category <> 'session_note'
  AND (content LIKE '%Weekly Book Snapshot%');

UPDATE public.persistent_memory
SET content = replace(content, 'book_snapshot_weekly_alert', 'agency_snapshot_weekly_alert'),
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND category <> 'session_note'
  AND content LIKE '%book_snapshot_weekly_alert%';

-- (7) Strip the stale INVENTORY UPDATE NEEDED block from the two-recipe enforcement row
UPDATE public.persistent_memory
SET content = regexp_replace(content,
    E'\n\nINVENTORY UPDATE NEEDED\n- operational_rule "BCC automation recipe inventory" needs to be bumped from 12 to 14 next time the inventory row is touched \\(Weekly (Book|Agency) Snapshot - Gmail Parse \\+ Weekly (Book|Agency) Snapshot - Manual Entry Alert added 2026-06-15\\)\\.\n?',
    '', 'g'),
  updated_at = NOW()
WHERE id = 'e8a41e2b-20cd-4109-af11-5043eaeeb11a';

COMMIT;
