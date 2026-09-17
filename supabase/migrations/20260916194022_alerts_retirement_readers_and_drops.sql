-- Alerts retirement, phase 2, step 3.
-- The functions that READ alerts, not just wrote them. Each read was doing a
-- job, so each one gets a real replacement rather than being deleted:
--   check_ci_build_status, huddle_calendar_sync, pfa_monthly_reconciliation
--     -> ensure_watcher_task / close_watcher_task
--   send_v1_assessment_invitations
--     -> hiring_candidates.assessment_completed_at, which the same code path
--        that used to write the completion alert already sets (verified: every
--        September completion alert has a matching timestamp within 1 second)
--   monthly_close_monitor, production_change_digest_daily,
--   run_migration_mirror_nightly, mark_license_complete, tg_post_gl_on_arrival
--     -> removed; the close checklist, Telegram, migration_mirror_runs,
--        license_notification_log and automation_run_log already carry them.
-- Patterns are written so no match can cross a statement boundary: Postgres
-- makes the whole regex greedy when the first quantifier is greedy, so a
-- non-greedy .*? here would swallow the rest of the function body.
DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  v_def := pg_get_functiondef('public.dispatch_license_reminders(uuid,uuid)'::regprocedure);
  v_new := replace(v_def, 'See license_notification_log + alerts.', 'See license_notification_log.');
  IF v_new = v_def THEN RAISE EXCEPTION 'no change: dispatch_license_reminders'; END IF;
  EXECUTE v_new;

  v_def := pg_get_functiondef('public.mark_license_complete(uuid,date)'::regprocedure);
  v_new := regexp_replace(v_def, 'UPDATE public\.alerts[^;]*;', 'NULL;', 'g');
  IF v_new ~* 'alerts' THEN RAISE EXCEPTION 'leftover: mark_license_complete'; END IF;
  EXECUTE v_new;

  v_def := pg_get_functiondef('public.check_ci_build_status(uuid,uuid,text)'::regprocedure);
  v_new := regexp_replace(v_def, 'UPDATE public\.alerts[^;]*;',
    $q$PERFORM public.close_watcher_task(p_agency_id, 'ci_build', NULL);$q$);
  v_new := regexp_replace(v_new,
    'IF EXISTS \(\s*SELECT 1 FROM public\.alerts[^;]*\) THEN RETURN 0; END IF;', 'NULL;');
  v_new := regexp_replace(v_new, 'INSERT INTO public\.alerts[^;]*;',
    $q$PERFORM public.ensure_watcher_task(
    p_agency_id, 'ci_build', NULL,
    'Build check failed on main: ' || coalesce(v_name, 'unknown check'),
    'Commit ' || left(v_sha, 10) || ' failed the check "' || coalesce(v_name, '?') ||
    '". The usual cause is an edge function bundle that was not rebuilt after its '
    || 'source changed, which means the deployed function is still running old code. '
    || 'Run: ' || v_url,
    'high', 'web_app');$q$);
  IF v_new ~* 'alerts' THEN RAISE EXCEPTION 'leftover: check_ci_build_status'; END IF;
  EXECUTE v_new;

  v_def := pg_get_functiondef('public.huddle_calendar_sync(uuid)'::regprocedure);
  v_new := regexp_replace(v_def,
    'IF NOT EXISTS \(\s*SELECT 1 FROM public\.alerts[^;]*\) THEN\s*INSERT INTO public\.alerts[^;]*;\s*END IF;',
    $q$PERFORM public.ensure_watcher_task(
            p_agency_id, 'huddle_calendar_sync', NULL,
            'Daily Kickoff calendar sync did not take',
            CASE WHEN v_gone
              THEN 'The calendar event Newtworks was updating no longer exists, so the update was refused. '
                || 'The stored pointer has been cleared and the next sync will create the series again. '
                || 'This happens when the series is edited in Google with "this and following events". '
                || 'What came back: ' || v_reason
              ELSE 'Google Calendar refused the huddle sync and nothing on the calendar changed. '
                || 'What came back: ' || v_reason
            END,
            CASE WHEN v_gone THEN 'medium' ELSE 'high' END,
            'admin');$q$);
  IF v_new ~* 'alerts' THEN RAISE EXCEPTION 'leftover: huddle_calendar_sync'; END IF;
  IF (length(v_new) - length(replace(v_new, 'IF v_failed THEN', ''))) / 16 <> 1
    THEN RAISE EXCEPTION 'huddle: IF v_failed THEN not unique'; END IF;
  v_new := replace(v_new, 'IF v_failed THEN',
    $q$IF NOT v_failed THEN
        PERFORM public.close_watcher_task(p_agency_id, 'huddle_calendar_sync', NULL);
      END IF;
      IF v_failed THEN$q$);
  EXECUTE v_new;

  v_def := pg_get_functiondef('public.monthly_close_monitor(uuid,uuid)'::regprocedure);
  v_new := regexp_replace(v_def, 'INSERT INTO public\.alerts[^;]*;', 'NULL;', 'g');
  v_new := regexp_replace(v_new, 'WITH satisfied AS \([^;]*;', '');
  v_new := replace(v_new, 'GET DIAGNOSTICS v_resolved_count = ROW_COUNT;', 'v_resolved_count := 0;');
  v_new := regexp_replace(v_new, '\s*--[^\n]*alert[^\n]*', '', 'gi');
  v_new := replace(v_new, ''' stale alerts auto-resolved, ''', ''' stale items auto-closed, ''');
  v_new := replace(v_new, ''' overdue alerts raised''', ''' overdue items found''');
  IF v_new ~* 'alerts' THEN RAISE EXCEPTION 'leftover: monthly_close_monitor'; END IF;
  EXECUTE v_new;

  v_def := pg_get_functiondef('public.production_change_digest_daily(uuid,uuid)'::regprocedure);
  v_new := regexp_replace(v_def, 'SELECT id INTO v_id FROM public\.alerts[^;]*;', '');
  v_new := regexp_replace(v_new,
    'IF v_id IS NULL THEN\s*INSERT INTO public\.alerts[^;]*;\s*ELSE\s*UPDATE public\.alerts[^;]*;\s*END IF;',
    'NULL;');
  IF v_new ~* 'alerts' THEN RAISE EXCEPTION 'leftover: production_change_digest_daily'; END IF;
  EXECUTE v_new;

  v_def := pg_get_functiondef('public.run_migration_mirror_nightly(uuid,uuid)'::regprocedure);
  v_new := regexp_replace(v_def,
    '-- One open alert at a time; do not restack every night\.\s*IF NOT EXISTS \(\s*SELECT 1 FROM public\.alerts[^;]*\) THEN\s*INSERT INTO public\.alerts[^;]*;\s*END IF;',
    'NULL;');
  IF v_new ~* 'alerts' THEN RAISE EXCEPTION 'leftover: run_migration_mirror_nightly'; END IF;
  EXECUTE v_new;

  v_def := pg_get_functiondef('public.tg_post_gl_on_arrival()'::regprocedure);
  v_new := replace(v_def,
$q$    INSERT INTO public.alerts
      (agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved)
    VALUES (v_agency_id, 'gl_posting_failure', 'high',
            'Posting to the ledger failed right after new records arrived',
            'The ' || v_writer || ' writer raised an error when ' || TG_TABLE_NAME ||
            ' received new rows. The records were saved; they are simply not posted yet. '
            || 'The nightly run will retry. Error: ' || SQLERRM,
            'financials', FALSE, FALSE);$q$, '    NULL;');
  IF v_new ~* 'alerts' THEN RAISE EXCEPTION 'leftover: tg_post_gl_on_arrival'; END IF;
  EXECUTE v_new;

  v_def := pg_get_functiondef('public.pfa_monthly_reconciliation(uuid,uuid)'::regprocedure);
  v_new := regexp_replace(v_def, 'INSERT INTO public\.alerts[^;]*;',
    $q$PERFORM public.ensure_watcher_task(p_agency_id, 'pfa_reconciliation_ready',
        v_recon_id, v_alert_title, v_alert_message, 'medium', 'finances');$q$);
  IF v_new ~* 'alerts' THEN RAISE EXCEPTION 'leftover: pfa_monthly_reconciliation'; END IF;
  EXECUTE v_new;

  v_def := pg_get_functiondef('public.send_v1_assessment_invitations(uuid,uuid)'::regprocedure);
  v_new := regexp_replace(v_def,
    'NOT EXISTS \(\s*SELECT 1 FROM public\.alerts a\s*WHERE a\.agency_id = p_agency_id\s*AND a\.alert_type = ANY \(v_done_alert_types\)\s*AND a\.related_id = hc\.id\s*\)',
    'hc.assessment_completed_at IS NULL', 'g');
  v_new := regexp_replace(v_new,
    '\(\s*SELECT 1 FROM public\.alerts a\s*WHERE a\.agency_id = p_agency_id\s*AND a\.alert_type = ANY \(v_done_alert_types\)\s*AND a\.related_id = ai\.candidate_id\s*AND a\.created_at >= ai\.sent_at\s*\)',
    '(
        SELECT 1 FROM public.hiring_candidates hc
        WHERE hc.id = ai.candidate_id
          AND hc.assessment_completed_at >= ai.sent_at
      )', 'g');
  v_new := regexp_replace(v_new,
    '\s*v_done_alert_types text\[\] := ARRAY\[''v1_assessment_complete'', ''v2_assessment_complete''\];', '');
  IF v_new ~* 'alerts' OR v_new ~* 'v_done_alert_types'
    THEN RAISE EXCEPTION 'leftover: send_v1_assessment_invitations'; END IF;
  EXECUTE v_new;
END $mig$;

-- Two functions whose only job was writing an alert. No callers in pg_proc and
-- none in the repo (checked both before dropping).
--  * fn_alert_on_recipe_run wrote the automation_failure alert, 2,608 of the
--    3,297 rows. automation_run_log already holds every one of those runs.
--  * run_rp_save_clear_reminder nagged about saves about to clear. The Activity
--    Log page already reads rp_saves_clearing_soon and shows them.
DROP TRIGGER IF EXISTS trg_alert_on_recipe_run ON public.automation_run_log;
DROP FUNCTION IF EXISTS public.fn_alert_on_recipe_run();
DROP FUNCTION IF EXISTS public.run_rp_save_clear_reminder(uuid, uuid);

UPDATE public.automation_recipes
   SET is_active = false
 WHERE internal_handler = 'run_rp_save_clear_reminder';

DO $verify$
DECLARE v_left int;
BEGIN
  SELECT count(*) INTO v_left
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND pg_get_functiondef(p.oid) ~* '(^|[^_a-z])(public\.)?alerts([^_a-z]|$)';
  IF v_left > 0 THEN
    RAISE EXCEPTION 'alerts retirement: % database functions still reference alerts', v_left;
  END IF;
END $verify$;
