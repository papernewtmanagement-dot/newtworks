-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-01 16:38:01 UTC (ledger name: renewal_mark_complete_function) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260701163801.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
CREATE OR REPLACE FUNCTION public.mark_renewal_complete(
  p_renewal_id uuid,
  p_completed_on date DEFAULT CURRENT_DATE
) RETURNS public.team_renewals
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.team_renewals;
  v_next_due date;
BEGIN
  SELECT * INTO v_row FROM public.team_renewals WHERE id = p_renewal_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'renewal not found: %', p_renewal_id;
  END IF;

  IF v_row.cycle_months IS NULL THEN
    -- One-time cert — mark complete_onetime and stop tracking future due
    UPDATE public.team_renewals
    SET status = 'complete_onetime',
        last_completed_at = p_completed_on
    WHERE id = p_renewal_id
    RETURNING * INTO v_row;

    -- Resolve any open alert
    UPDATE public.alerts
    SET is_resolved = true, resolved_at = now()
    WHERE module_reference = 'team_renewals'
      AND related_id = p_renewal_id
      AND is_resolved = false;

    RETURN v_row;
  END IF;

  -- Recurring — advance due_date by cycle_months from either the completion
  -- date or the previous due_date (whichever is later, so we don't lose time
  -- if Peter marks it complete a week early).
  v_next_due := (GREATEST(p_completed_on, v_row.due_date)
                 + (v_row.cycle_months || ' months')::interval)::date;

  UPDATE public.team_renewals
  SET due_date = v_next_due,
      last_completed_at = p_completed_on,
      -- After the first completion, CE becomes required on future cycles
      ce_required = CASE
        WHEN v_row.ce_required = false AND v_row.initial_issue_date IS NOT NULL
          THEN true
        ELSE v_row.ce_required
      END
  WHERE id = p_renewal_id
  RETURNING * INTO v_row;

  -- Resolve any open alert; the daily cron will create a fresh one when the
  -- new due date enters the 90-day window.
  UPDATE public.alerts
  SET is_resolved = true, resolved_at = now()
  WHERE module_reference = 'team_renewals'
    AND related_id = p_renewal_id
    AND is_resolved = false;

  -- Clear historical notification log entries so cadence hits fire fresh
  -- for the new cycle (past-due negative rows would otherwise block sends).
  DELETE FROM public.renewal_notification_log
  WHERE team_renewal_id = p_renewal_id;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.mark_renewal_complete(uuid, date) TO authenticated, anon;
