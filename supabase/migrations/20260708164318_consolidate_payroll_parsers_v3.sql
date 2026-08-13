-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-08 16:43:18 UTC (ledger name: consolidate_payroll_parsers_v3) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260708164318.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Consolidate payroll email parsing into document-processor v36

-- 1. Deactivate the redundant daily "Payroll Summary Ingest" recipe.
UPDATE automation_recipes
SET is_active = false,
    updated_at = now(),
    recipe_description = COALESCE(recipe_description, '') ||
      E'\n\n[2026-07-07] DEACTIVATED: consolidated into document-processor v36. SurePayroll emails now ingested every 30 min via standard doc-processor pipeline.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND internal_handler = 'dispatch_payroll_email_parser';

-- 2. Update payroll_weekly_nag to fire document-processor instead of payroll-email-parser
CREATE OR REPLACE FUNCTION public.payroll_weekly_nag(
  p_agency_id uuid,
  p_recipe_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ct_today          date;
  v_pay_period_end    date;
  v_alert_key         text;
  v_alert_id          uuid;
  v_existing_run      uuid;
  v_url               text;
  v_secret            text;
  v_peter_chat_id     text;
  v_message           text;
BEGIN
  v_ct_today := (now() AT TIME ZONE 'America/Chicago')::date;
  v_pay_period_end := v_ct_today - ((EXTRACT(DOW FROM v_ct_today)::int + 1) % 7);

  SELECT setting_value INTO v_url FROM settings WHERE agency_id = p_agency_id AND setting_key = 'supabase_url';
  SELECT setting_value INTO v_secret FROM settings WHERE agency_id = p_agency_id AND setting_key = 'automation_runner_cron_secret';

  IF v_url IS NOT NULL AND v_secret IS NOT NULL THEN
    PERFORM net.http_post(
      url     := v_url || '/functions/v1/document-processor',
      body    := jsonb_build_object(
        'agency_id', p_agency_id,
        'shared_secret', v_secret,
        'gmail_query', 'from:statefarm.com subject:payroll has:attachment newer_than:7d',
        'max_results', 10
      ),
      headers := jsonb_build_object('Content-Type', 'application/json'),
      timeout_milliseconds := 60000
    );
    PERFORM pg_sleep(3);
  END IF;

  SELECT id INTO v_existing_run
  FROM payroll_runs
  WHERE agency_id = p_agency_id AND pay_period_end = v_pay_period_end
  ORDER BY created_at DESC LIMIT 1;

  IF v_existing_run IS NOT NULL THEN
    RETURN jsonb_build_object(
      'status', 'skipped',
      'reason', 'payroll_already_imported',
      'pay_period_end', v_pay_period_end,
      'payroll_run_id', v_existing_run
    );
  END IF;

  v_alert_key := 'payroll_run:' || v_pay_period_end::text;

  SELECT id INTO v_alert_id
  FROM alerts
  WHERE agency_id = p_agency_id
    AND module_reference = 'payroll_run'
    AND alert_key = v_alert_key
    AND is_resolved = false
  LIMIT 1;

  IF v_alert_id IS NULL THEN
    INSERT INTO alerts (
      agency_id, alert_type, severity, title, description,
      module_reference, alert_key, due_date, is_resolved, created_at, updated_at
    )
    VALUES (
      p_agency_id, 'payroll_missing', 'warning',
      'Payroll not yet imported for period ending ' || v_pay_period_end::text,
      'Weekly payroll has not been imported for the pay period ending ' || v_pay_period_end::text || '. Forward from statefarm.com to paper.newt.management@gmail.com, or fire doc-processor manually.',
      'payroll_run', v_alert_key, v_pay_period_end + 4,
      false, now(), now()
    )
    RETURNING id INTO v_alert_id;
  END IF;

  SELECT setting_value INTO v_peter_chat_id FROM settings WHERE agency_id = p_agency_id AND setting_key = 'peter_telegram_chat_id';

  IF v_peter_chat_id IS NOT NULL THEN
    v_message := E'⚠️ *Payroll reminder*\n\n' ||
                 E'Payroll for period ending *' || v_pay_period_end::text || E'* not yet imported.\n\n' ||
                 E'Forward the SurePayroll summary from statefarm.com to paper.newt.management@gmail.com.';
    PERFORM telegram_send_message_v2(v_peter_chat_id, v_message, 'paper_newt', 'Markdown', NULL);
  END IF;

  RETURN jsonb_build_object(
    'status', 'nag_sent',
    'pay_period_end', v_pay_period_end,
    'alert_id', v_alert_id,
    'telegram_sent', v_peter_chat_id IS NOT NULL
  );
END;
$$;

-- 3. Update apply_ct_cron_dst_sync — fix the DST detection (was previously
--    broken with TIMEZONE_HOUR on tz-naive timestamp) AND drop dispatch_payroll_email_parser
CREATE OR REPLACE FUNCTION public.apply_ct_cron_dst_sync()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_offset_hours int;
  v_nag_cron_utc text;
BEGIN
  -- CT is behind UTC. (CT wall-clock) - (UTC wall-clock) = -5h (CDT) or -6h (CST)
  -- ABS gives us 5 or 6.
  v_offset_hours := ABS(
    EXTRACT(EPOCH FROM (
      (now() AT TIME ZONE 'America/Chicago')::timestamp
      - (now() AT TIME ZONE 'UTC')::timestamp
    ))::int / 3600
  );

  IF v_offset_hours = 5 THEN
    v_nag_cron_utc := '0 12';  -- CDT: 07:00 CT = 12:00 UTC
  ELSE
    v_nag_cron_utc := '0 13';  -- CST: 07:00 CT = 13:00 UTC
  END IF;

  UPDATE automation_recipes
  SET cron_expression = v_nag_cron_utc || ' * * 0-3',
      updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND internal_handler = 'payroll_weekly_nag'
    AND is_active = true;

  UPDATE automation_recipes
  SET cron_expression = v_nag_cron_utc || ' * * *',
      updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND internal_handler = 'pfa_monthly_nag'
    AND is_active = true;

  RETURN jsonb_build_object(
    'ct_offset_hours', v_offset_hours,
    'nag_cron_utc_base', v_nag_cron_utc,
    'timestamp', now()
  );
END;
$$;

-- Apply immediately
SELECT public.apply_ct_cron_dst_sync();
