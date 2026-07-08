-- 20260707230200_restore_license_functions_correctly_v2
-- Restores the three license-related functions with their full bodies. The prior
-- rename migration DROP+CREATEd them with placeholder bodies; this migration
-- recovers the originals (source: supabase/schema_snapshots/functions_2026-07-02.sql).

CREATE OR REPLACE FUNCTION public.tg_team_licenses_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.mark_license_complete(p_license_id uuid, p_completed_on date DEFAULT CURRENT_DATE)
 RETURNS team_licenses
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row public.team_licenses;
  v_next_due date;
BEGIN
  SELECT * INTO v_row FROM public.team_licenses WHERE id = p_license_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'license not found: %', p_license_id;
  END IF;

  IF v_row.cycle_months IS NULL THEN
    UPDATE public.team_licenses
    SET status = 'complete_onetime',
        last_completed_at = p_completed_on
    WHERE id = p_license_id
    RETURNING * INTO v_row;

    UPDATE public.alerts
    SET is_resolved = true, resolved_at = now()
    WHERE module_reference = 'team_licenses'
      AND related_id = p_license_id
      AND is_resolved = false;

    RETURN v_row;
  END IF;

  v_next_due := (GREATEST(p_completed_on, v_row.due_date)
                 + (v_row.cycle_months || ' months')::interval)::date;

  UPDATE public.team_licenses
  SET due_date = v_next_due,
      last_completed_at = p_completed_on,
      ce_required = CASE
        WHEN v_row.ce_required = false AND v_row.initial_issue_date IS NOT NULL
          THEN true
        ELSE v_row.ce_required
      END
  WHERE id = p_license_id
  RETURNING * INTO v_row;

  UPDATE public.alerts
  SET is_resolved = true, resolved_at = now()
  WHERE module_reference = 'team_licenses'
    AND related_id = p_license_id
    AND is_resolved = false;

  DELETE FROM public.license_notification_log
  WHERE team_license_id = p_license_id;

  RETURN v_row;
END;
$function$;

-- dispatch_license_reminders was later repointed to license-reminder-runner slug in
-- 20260708002628_repoint_dispatch_license_reminders_to_new_slug. That migration
-- superseded the body created here; not restated to avoid drift.
