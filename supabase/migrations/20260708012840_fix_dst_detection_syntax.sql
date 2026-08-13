-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-08 01:28:40 UTC (ledger name: fix_dst_detection_syntax) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260708012840.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

CREATE OR REPLACE FUNCTION public.apply_ct_cron_dst_sync()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $$
DECLARE
  v_is_cdt      boolean;
  v_hour_2am_ct int;
  v_hour_7am_ct int;
  v_changes     int := 0;
  v_expected_ingest text;
  v_expected_weekly text;
  v_expected_pfa    text;
  v_current_ingest  text;
  v_current_weekly  text;
  v_current_pfa     text;
BEGIN
  -- DST detection: compare hour-of-day between UTC and America/Chicago.
  -- If diff = 5, we're in CDT (UTC-5); if diff = 6, we're in CST (UTC-6).
  -- Using extract(hour) with a same-instant conversion.
  v_is_cdt := (
    EXTRACT(EPOCH FROM (now() - (now() AT TIME ZONE 'America/Chicago')))::int
    = 5 * 3600
  );

  v_hour_2am_ct := CASE WHEN v_is_cdt THEN 7  ELSE 8  END;
  v_hour_7am_ct := CASE WHEN v_is_cdt THEN 12 ELSE 13 END;

  v_expected_ingest := format('0 %s * * *',       v_hour_2am_ct);
  v_expected_weekly := format('0 %s * * 0,1,2,3', v_hour_7am_ct);
  v_expected_pfa    := format('0 %s * * *',       v_hour_7am_ct);

  SELECT cron_expression INTO v_current_ingest FROM automation_recipes WHERE internal_handler='dispatch_payroll_email_parser' LIMIT 1;
  SELECT cron_expression INTO v_current_weekly FROM automation_recipes WHERE internal_handler='payroll_weekly_nag'           LIMIT 1;
  SELECT cron_expression INTO v_current_pfa    FROM automation_recipes WHERE internal_handler='pfa_monthly_nag'              LIMIT 1;

  IF v_current_ingest IS DISTINCT FROM v_expected_ingest THEN
    UPDATE automation_recipes SET cron_expression = v_expected_ingest, updated_at = now() WHERE internal_handler='dispatch_payroll_email_parser';
    v_changes := v_changes + 1;
  END IF;
  IF v_current_weekly IS DISTINCT FROM v_expected_weekly THEN
    UPDATE automation_recipes SET cron_expression = v_expected_weekly, updated_at = now() WHERE internal_handler='payroll_weekly_nag';
    v_changes := v_changes + 1;
  END IF;
  IF v_current_pfa IS DISTINCT FROM v_expected_pfa THEN
    UPDATE automation_recipes SET cron_expression = v_expected_pfa, updated_at = now() WHERE internal_handler='pfa_monthly_nag';
    v_changes := v_changes + 1;
  END IF;

  RETURN jsonb_build_object(
    'is_cdt', v_is_cdt,
    'expected_ingest', v_expected_ingest,
    'expected_weekly', v_expected_weekly,
    'expected_pfa', v_expected_pfa,
    'changes_applied', v_changes,
    'output_summary', format('DST sync ran (%s CT). %s recipe cron_expression change(s).', CASE WHEN v_is_cdt THEN 'CDT' ELSE 'CST' END, v_changes),
    'records_processed', v_changes
  );
END;
$$;
