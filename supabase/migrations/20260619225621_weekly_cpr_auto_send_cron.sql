-- Wrapper function the cron calls. Determines the most recent Saturday in CT,
-- checks readiness, and either fires send_weekly_cpr_recap or skips silently.
CREATE OR REPLACE FUNCTION public.try_send_weekly_cpr_recap()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net
AS $func$
DECLARE
  v_agency_id  uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_now_ct     timestamp;
  v_today_ct   date;
  v_week_end   date;
  v_dow        int;
  v_report     record;
  v_send_res   jsonb;
BEGIN
  v_now_ct   := (NOW() AT TIME ZONE 'America/Chicago');
  v_today_ct := v_now_ct::date;
  v_dow      := EXTRACT(DOW FROM v_today_ct)::int;
  -- Most recent Saturday on or before today (in CT). DOW: 0=Sun..6=Sat.
  v_week_end := v_today_ct - ((v_dow + 1) % 7);

  SELECT * INTO v_report
  FROM public.weekly_cpr_reports
  WHERE agency_id = v_agency_id AND week_ending_date = v_week_end;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('fired', false, 'skipped', 'no_report_row', 'week_ending_date', v_week_end);
  END IF;

  IF v_report.sent_to_team_at IS NOT NULL THEN
    RETURN jsonb_build_object('fired', false, 'skipped', 'already_sent', 'sent_to_team_at', v_report.sent_to_team_at);
  END IF;

  IF v_report.opener_text IS NULL OR length(btrim(v_report.opener_text)) < 100 THEN
    RETURN jsonb_build_object('fired', false, 'skipped', 'opener_not_ready', 'week_ending_date', v_week_end);
  END IF;

  IF v_report.looking_next_week_text IS NULL OR length(btrim(v_report.looking_next_week_text)) < 50 THEN
    RETURN jsonb_build_object('fired', false, 'skipped', 'looking_ahead_not_ready', 'week_ending_date', v_week_end);
  END IF;

  v_send_res := public.send_weekly_cpr_recap(v_agency_id, v_week_end);

  RETURN jsonb_build_object('fired', true, 'week_ending_date', v_week_end, 'send_result', v_send_res);
END;
$func$;

GRANT EXECUTE ON FUNCTION public.try_send_weekly_cpr_recap() TO authenticated, anon, service_role;

-- Schedule: Sun 04:59 UTC = Sat 23:59 CDT and Mon 04:59 UTC = Sun 23:59 CDT.
-- In winter (CST) these fire at 22:59 CT instead of 23:59 CT - still fine.
-- Remove any prior schedule of this name first.
DO $$
DECLARE
  v_jid bigint;
BEGIN
  SELECT jobid INTO v_jid FROM cron.job WHERE jobname = 'weekly_cpr_auto_send';
  IF v_jid IS NOT NULL THEN
    PERFORM cron.unschedule(v_jid);
  END IF;
END $$;

SELECT cron.schedule(
  'weekly_cpr_auto_send',
  '59 4 * * 0,1',
  $cmd$ SELECT public.try_send_weekly_cpr_recap(); $cmd$
);
