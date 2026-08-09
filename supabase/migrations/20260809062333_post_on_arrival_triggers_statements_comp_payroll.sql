-- Peter directive 2026-08-09: posting to the ledger must happen the moment records land,
-- not on the nightly schedule. Three canon tables feed the ledger, so three triggers.
--
-- Design decisions, all deliberate:
--  * FOR EACH STATEMENT, not FOR EACH ROW. A bulk insert of 300 rows fires once, not 300 times.
--  * The writer's own already-posted check means re-running is harmless and idempotent.
--  * Posting failure must NEVER roll back an ingest. The handler catches, records an alert
--    and a run-log row, and lets the insert stand. This is not a silent swallow - every
--    failure is visible in alerts and automation_run_log.
--  * The writer's report (unclassified counts, errors) is written to automation_run_log so
--    running from a trigger does not lose the visibility the nightly run gave.
--  * Escape hatch for bulk historical loads: SET LOCAL app.defer_gl_posting = 'on' inside a
--    transaction skips the trigger, so a large re-parse can post once at the end instead of
--    after every insert. Session-scoped, never a permanent setting.
--  * The nightly recipes stay active as a backstop. Belt and braces on purpose.

CREATE OR REPLACE FUNCTION public.tg_post_gl_on_arrival()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_agency_id uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_writer text := TG_ARGV[0];
  v_result jsonb;
  v_started timestamptz := clock_timestamp();
BEGIN
  -- Bulk-load escape hatch.
  IF coalesce(current_setting('app.defer_gl_posting', TRUE), 'off') = 'on' THEN
    RETURN NULL;
  END IF;

  BEGIN
    IF v_writer = 'statement' THEN
      -- 2026-01-01 floor: pre-2026 profit and loss lives in prior_year_pl, never the ledger.
      v_result := public.statement_gl_writer(v_agency_id, NULL::uuid, DATE '2026-01-01', NULL::date, FALSE);
    ELSIF v_writer = 'comp' THEN
      v_result := public.comp_gl_writer(v_agency_id, FALSE);
    ELSIF v_writer = 'payroll' THEN
      v_result := public.payroll_gl_writer(v_agency_id, FALSE, NULL::date);
    ELSE
      RAISE EXCEPTION 'tg_post_gl_on_arrival: unknown writer argument %', v_writer;
    END IF;

    INSERT INTO public.automation_run_log
      (agency_id, run_at, status, error_message, duration_seconds, output_summary)
    VALUES (v_agency_id, NOW(), 'success', NULL,
            GREATEST(1, EXTRACT(EPOCH FROM (clock_timestamp() - v_started))::int),
            'post-on-arrival trigger (' || v_writer || ' writer, table ' || TG_TABLE_NAME || '): ' || v_result::text);

  EXCEPTION WHEN OTHERS THEN
    -- Never fail the ingest because posting failed. Record it loudly instead.
    INSERT INTO public.automation_run_log
      (agency_id, run_at, status, error_message, duration_seconds, output_summary)
    VALUES (v_agency_id, NOW(), 'failed', SQLERRM,
            GREATEST(1, EXTRACT(EPOCH FROM (clock_timestamp() - v_started))::int),
            'post-on-arrival trigger (' || v_writer || ' writer, table ' || TG_TABLE_NAME || ') FAILED');

    INSERT INTO public.alerts
      (agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved)
    VALUES (v_agency_id, 'gl_posting_failure', 'high',
            'Posting to the ledger failed right after new records arrived',
            'The ' || v_writer || ' writer raised an error when ' || TG_TABLE_NAME ||
            ' received new rows. The records were saved; they are simply not posted yet. '
            || 'The nightly run will retry. Error: ' || SQLERRM,
            'financials', FALSE, FALSE);
  END;

  RETURN NULL;
END;
$function$;

COMMENT ON FUNCTION public.tg_post_gl_on_arrival() IS
  'Statement-level AFTER INSERT handler that runs the matching general-ledger writer as soon as canon records land. TG_ARGV[0] selects the writer: statement, comp or payroll. Failures are logged to automation_run_log and alerts and never roll back the ingest. SET LOCAL app.defer_gl_posting = ''on'' to skip during bulk historical loads.';

DROP TRIGGER IF EXISTS trg_post_gl_on_arrival_statements ON public.statements;
CREATE TRIGGER trg_post_gl_on_arrival_statements
AFTER INSERT ON public.statements
FOR EACH STATEMENT EXECUTE FUNCTION public.tg_post_gl_on_arrival('statement');

DROP TRIGGER IF EXISTS trg_post_gl_on_arrival_comp_recap ON public.comp_recap;
CREATE TRIGGER trg_post_gl_on_arrival_comp_recap
AFTER INSERT ON public.comp_recap
FOR EACH STATEMENT EXECUTE FUNCTION public.tg_post_gl_on_arrival('comp');

DROP TRIGGER IF EXISTS trg_post_gl_on_arrival_payroll_detail ON public.payroll_detail;
CREATE TRIGGER trg_post_gl_on_arrival_payroll_detail
AFTER INSERT ON public.payroll_detail
FOR EACH STATEMENT EXECUTE FUNCTION public.tg_post_gl_on_arrival('payroll');
