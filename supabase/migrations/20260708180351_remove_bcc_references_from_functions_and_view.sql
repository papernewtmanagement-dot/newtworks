-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-08 18:03:51 UTC (ledger name: remove_bcc_references_from_functions_and_view) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260708180351.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Remove remaining BCC references from function bodies, view, and recipe description.
CREATE OR REPLACE FUNCTION public.huddle_calendar_sync(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
DECLARE
  v public.agency_huddle_config%ROWTYPE;
  v_api_key text;
  v_user_id text;
  v_connected_account_id text;
  v_pg_net_id bigint;
  v_attendees jsonb;
  v_start_ts text;
  v_action text;
  v_arguments jsonb;
BEGIN
  SELECT * INTO v FROM public.agency_huddle_config
  WHERE agency_id = p_agency_id
    AND calendar_needs_sync = true
    AND calendar_id IS NOT NULL;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','noop','reason','no rows flagged');
  END IF;

  SELECT setting_value INTO v_api_key
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_api_key';
  SELECT setting_value INTO v_user_id
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_user_id';
  SELECT setting_value INTO v_connected_account_id
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_googlecalendar_account_id';
  IF v_api_key IS NULL OR v_user_id IS NULL OR v_connected_account_id IS NULL THEN
    RAISE EXCEPTION 'Composio Google Calendar config missing in settings';
  END IF;

  SELECT jsonb_agg(email) INTO v_attendees FROM (
    SELECT email_sf AS email FROM public.team
    WHERE agency_id = p_agency_id AND category='agency'
      AND is_admin_backoffice=false AND is_active=true
      AND email_sf IS NOT NULL AND email_sf <> ''
    UNION ALL
    SELECT email_personal FROM public.team
    WHERE agency_id = p_agency_id AND category='agency'
      AND is_admin_backoffice=false AND is_active=true
      AND email_personal IS NOT NULL AND email_personal <> ''
  ) e;

  v_start_ts := COALESCE(v.event_first_date, CURRENT_DATE)::text
                || 'T' || TO_CHAR(v.start_time_local, 'HH24:MI:SS');

  IF v.calendar_event_id IS NULL THEN
    v_action := 'GOOGLECALENDAR_CREATE_EVENT';
    v_arguments := jsonb_build_object(
      'calendar_id',            v.calendar_id,
      'summary',                v.event_title,
      'description',            'Story Agency team huddle. Managed via Newtworks. Rhythm + this week''s leader in Newtworks → Processes → Daily Kickoff.',
      'start_datetime',         v_start_ts,
      'timezone',               'America/Chicago',
      'event_duration_hour',    0,
      'event_duration_minutes', v.duration_regular_min,
      'recurrence',             jsonb_build_array('RRULE:FREQ=WEEKLY;BYDAY=' || array_to_string(v.days_of_week, ',')),
      'attendees',              COALESCE(v_attendees, '[]'::jsonb),
      'create_meeting_room',    true,
      'exclude_organizer',      true,
      'send_updates',           'all',
      'guestsCanInviteOthers',  false,
      'guestsCanSeeOtherGuests', true
    );
  ELSE
    v_action := 'GOOGLECALENDAR_UPDATE_EVENT';
    v_arguments := jsonb_build_object(
      'calendar_id',            v.calendar_id,
      'event_id',               v.calendar_event_id,
      'summary',                v.event_title,
      'start_datetime',         v_start_ts,
      'timezone',               'America/Chicago',
      'event_duration_hour',    0,
      'event_duration_minutes', v.duration_regular_min,
      'recurrence',             jsonb_build_array('RRULE:FREQ=WEEKLY;BYDAY=' || array_to_string(v.days_of_week, ',')),
      'attendees',              COALESCE(v_attendees, '[]'::jsonb),
      'send_updates',           'all'
    );
  END IF;

  SELECT net.http_post(
    url     := 'https://backend.composio.dev/api/v3/tools/execute/' || v_action,
    headers := jsonb_build_object('x-api-key', v_api_key, 'Content-Type', 'application/json'),
    body    := jsonb_build_object(
      'user_id',              v_user_id,
      'connected_account_id', v_connected_account_id,
      'arguments',            v_arguments
    )
  ) INTO v_pg_net_id;

  UPDATE public.agency_huddle_config
  SET calendar_needs_sync = false,
      calendar_last_synced_at = NOW()
  WHERE agency_id = p_agency_id;

  RETURN jsonb_build_object(
    'status','dispatched',
    'action', v_action,
    'pg_net_id', v_pg_net_id,
    'start_datetime', v_start_ts
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.payroll_weekly_nag(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'pg_catalog'
AS $function$
DECLARE
  v_url               text;
  v_secret            text;
  v_target_sat        date;
  v_next_wed          date;
  v_run_exists        boolean;
  v_existing_alert_id uuid;
  v_mod_ref           text;
  v_title             text;
  v_message           text;
  v_peter_tg          bigint;
  v_tg_resp           jsonb;
  v_dm_text           text;
  v_action_taken      text := 'no-op';
BEGIN
  v_target_sat := current_date - ((extract(dow from current_date)::int + 1) % 7);
  v_next_wed   := v_target_sat + 4;
  v_mod_ref    := 'payroll_run:' || v_target_sat::text;

  BEGIN
    SELECT setting_value INTO v_url    FROM public.settings WHERE agency_id=p_agency_id AND setting_key='supabase_url';
    SELECT setting_value INTO v_secret FROM public.settings WHERE agency_id=p_agency_id AND setting_key='automation_runner_cron_secret';
    IF v_url IS NOT NULL AND v_secret IS NOT NULL THEN
      PERFORM net.http_post(
        url     := v_url || '/functions/v1/payroll-email-parser',
        body    := jsonb_build_object('agency_id', p_agency_id, 'shared_secret', v_secret),
        headers := jsonb_build_object('Content-Type','application/json'),
        timeout_milliseconds := 60000
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  SELECT EXISTS (SELECT 1 FROM public.payroll_runs WHERE agency_id = p_agency_id AND pay_period_end = v_target_sat) INTO v_run_exists;
  IF v_run_exists THEN
    RETURN jsonb_build_object('records_processed', 0, 'output_summary', format('Payroll for week ending %s already imported; no nag needed.', v_target_sat));
  END IF;

  SELECT ttm.telegram_user_id INTO v_peter_tg FROM public.team_telegram_map ttm
   JOIN public.team t ON t.id = ttm.team_id WHERE t.first_name='Peter' AND t.last_name='Story' LIMIT 1;
  v_peter_tg := COALESCE(v_peter_tg, 7778113542);

  SELECT id INTO v_existing_alert_id FROM public.alerts
   WHERE agency_id = p_agency_id AND module_reference = v_mod_ref AND COALESCE(is_resolved, false) = false LIMIT 1;

  v_title := format('Run payroll for week ending %s', to_char(v_target_sat, 'Mon DD'));
  v_message := format('No SurePayroll email received yet for pay period ending %s (transmit deadline: Wed %s). Submit payroll in SurePayroll, then forward the summary email to paper.newt.management@gmail.com so it lands in Newtworks.',
    to_char(v_target_sat, 'Mon DD, YYYY'), to_char(v_next_wed, 'Mon DD'));

  IF v_existing_alert_id IS NULL THEN
    INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved, due_date, created_at)
    VALUES (p_agency_id, 'payroll_reminder', 'warning', v_title, v_message, v_mod_ref, false, false, v_next_wed, now());
    v_action_taken := 'alert_created_and_dm_sent';
  ELSE
    v_action_taken := 'dm_resent';
  END IF;

  v_dm_text := format(E'⏰ Payroll reminder\n\nWeek ending: %s\nTransmit deadline: Wed %s\n\nRun payroll in SurePayroll, then forward the summary email to paper.newt.management@gmail.com.\n\n(This nag will stop once the summary email is auto-imported.)',
    to_char(v_target_sat, 'Mon DD, YYYY'), to_char(v_next_wed, 'Mon DD'));
  v_tg_resp := public.telegram_send_message_v2(v_peter_tg, v_dm_text, 'paper_newt');

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format('%s for week ending %s. Telegram DM ok=%s', v_action_taken, v_target_sat, COALESCE((v_tg_resp->>'ok')::text, 'unknown')),
    'target_pay_period_end', v_target_sat, 'transmit_deadline', v_next_wed, 'telegram_response', v_tg_resp
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.pfa_monthly_nag(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_month_key         text := to_char(current_date, 'YYYY-MM');
  v_month_name        text := to_char(current_date, 'FMMonth YYYY');
  v_mod_ref           text := 'pfa_submission:' || v_month_key;
  v_due_date          date := (date_trunc('month', current_date) + interval '9 days')::date;
  v_existing_alert_id uuid;
  v_peter_tg          bigint;
  v_tg_resp           jsonb;
  v_dm_text           text;
  v_action_taken      text;
BEGIN
  SELECT ttm.telegram_user_id INTO v_peter_tg FROM public.team_telegram_map ttm
   JOIN public.team t ON t.id = ttm.team_id WHERE t.first_name='Peter' AND t.last_name='Story' LIMIT 1;
  v_peter_tg := COALESCE(v_peter_tg, 7778113542);

  SELECT id INTO v_existing_alert_id FROM public.alerts
   WHERE agency_id = p_agency_id AND module_reference = v_mod_ref AND COALESCE(is_resolved, false) = false LIMIT 1;

  IF v_existing_alert_id IS NULL THEN
    IF extract(day from current_date) <= 10 THEN
      INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved, due_date, created_at)
      VALUES (p_agency_id, 'pfa_submission', 'warning',
        format('Submit PFA for %s', v_month_name),
        format('Submit this month''s Premium Fund Account (PFA) transaction in State Farm. Due by %s. Tap ''Mark Resolved'' on this alert once submitted.', to_char(v_due_date, 'FMMon DD')),
        v_mod_ref, false, false, v_due_date, now());
      v_action_taken := 'alert_created_and_dm_sent';
    ELSE
      RETURN jsonb_build_object('records_processed', 0, 'output_summary', format('No PFA alert for %s and past day 10; skipping.', v_month_key));
    END IF;
  ELSE
    v_action_taken := 'dm_resent';
  END IF;

  v_dm_text := format(E'💰 PFA reminder\n\n%s Premium Fund Account transaction is due by %s.\n\nSubmit it in State Farm, then tap "Mark Resolved" on the alert card in Newtworks.',
    v_month_name, to_char(v_due_date, 'FMMon DD'));
  v_tg_resp := public.telegram_send_message_v2(v_peter_tg, v_dm_text, 'paper_newt');

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format('%s for PFA %s. Telegram DM ok=%s', v_action_taken, v_month_key, COALESCE((v_tg_resp->>'ok')::text, 'unknown')),
    'month', v_month_key, 'due_date', v_due_date, 'telegram_response', v_tg_resp
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_time_off_email_vote_reply()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_request RECORD;
  v_voter_id uuid;
  v_alert_ref text;
BEGIN
  IF NEW.request_token IS NULL OR LENGTH(NEW.request_token) <> 8 THEN
    NEW.processing_status := 'no_token';
    NEW.processing_note   := 'Reply subject did not contain [#xxxxxxxx] token';
    NEW.processed_at      := NOW();
    RETURN NEW;
  END IF;

  SELECT r.id, r.status, r.vote_closes_at, r.requester_team_id
  INTO v_request
  FROM public.time_off_requests r
  WHERE r.agency_id = NEW.agency_id
    AND SUBSTRING(r.id::text, 1, 8) = LOWER(NEW.request_token)
  LIMIT 1;

  IF NOT FOUND THEN
    NEW.processing_status := 'no_request_match';
    NEW.processing_note   := 'No request found for token ' || NEW.request_token;
    NEW.processed_at      := NOW();
    RETURN NEW;
  END IF;
  NEW.resolved_request_id := v_request.id;

  SELECT id INTO v_voter_id
  FROM public.team
  WHERE agency_id = NEW.agency_id
    AND archived_at IS NULL
    AND (LOWER(email_sf) = LOWER(NEW.sender_email) OR LOWER(email_personal) = LOWER(NEW.sender_email))
  LIMIT 1;

  IF v_voter_id IS NULL THEN
    NEW.processing_status := 'voter_not_recognized';
    NEW.processing_note   := 'No active team member with email ' || NEW.sender_email;
    NEW.processed_at      := NOW();
    RETURN NEW;
  END IF;
  NEW.resolved_voter_team_id := v_voter_id;

  IF v_voter_id = v_request.requester_team_id THEN
    NEW.processing_status := 'voter_not_eligible';
    NEW.processing_note   := 'Voter is the requester';
    NEW.processed_at      := NOW();
    RETURN NEW;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.get_expected_teammates(NEW.agency_id, 'work_checkin')
    WHERE team_id = v_voter_id
  ) THEN
    NEW.processing_status := 'voter_not_eligible';
    NEW.processing_note   := 'Voter not on work_checkin roster (canonical)';
    NEW.processed_at      := NOW();
    RETURN NEW;
  END IF;

  IF v_request.status NOT IN ('voting', 'awaiting_decision') THEN
    NEW.processing_status := 'vote_closed';
    NEW.processing_note   := 'Request status is ' || v_request.status || ' — vote not recorded';
    NEW.processed_at      := NOW();
    RETURN NEW;
  END IF;

  IF NEW.received_at > v_request.vote_closes_at + INTERVAL '1 hour' THEN
    NEW.processing_status := 'vote_closed';
    NEW.processing_note   := 'Reply received after vote_closes_at + 1h grace';
    NEW.processed_at      := NOW();
    RETURN NEW;
  END IF;

  IF NEW.vote IS NULL OR NEW.vote NOT IN ('yes','no','abstain') THEN
    NEW.processing_status := 'no_vote_classified';
    NEW.processing_note   := 'Reply text could not be auto-classified';
    NEW.processed_at      := NOW();
    v_alert_ref := 'time_off_vote_reply_unclassified:' || NEW.source_message_id;
    IF NOT EXISTS (SELECT 1 FROM public.alerts WHERE agency_id = NEW.agency_id AND module_reference = v_alert_ref) THEN
      INSERT INTO public.alerts (agency_id, module_reference, severity, title, message, is_resolved)
      VALUES (NEW.agency_id, v_alert_ref, 'info',
              'Email vote reply could not be auto-classified',
              'Reply from ' || NEW.sender_email || ' on request [#' || NEW.request_token ||
                '] could not be classified as yes/no/abstain. Reply: "' ||
                COALESCE(LEFT(NEW.raw_snippet, 240), '(no snippet)') ||
                '". Open Newtworks > Time Off to vote manually if appropriate.',
              false);
    END IF;
    RETURN NEW;
  END IF;

  INSERT INTO public.time_off_votes (request_id, voter_team_id, vote, reason, voted_at)
  VALUES (v_request.id, v_voter_id, NEW.vote, NEW.reason, NEW.received_at)
  ON CONFLICT (request_id, voter_team_id)
  DO UPDATE SET vote = EXCLUDED.vote, reason = EXCLUDED.reason, voted_at = EXCLUDED.voted_at;

  NEW.processing_status := 'recorded';
  NEW.processed_at      := NOW();
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.team_checkin_send_reminder(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_input_config jsonb;
  v_checkin_type text;
  v_local_time text;
  v_chat_id bigint;
  v_today date;
  v_dow int;
  v_text text;
  v_response jsonb;
  v_message_id bigint;
  v_quote record;
  v_last_eod_date date;
  v_block record;
  v_pending_votes int;
  v_is_recovery boolean := false;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_checkin_type := v_input_config->>'checkin_type';
  v_local_time := v_input_config->>'local_time';

  IF v_checkin_type NOT IN ('morning', 'midday', 'eod') THEN
    RAISE EXCEPTION 'Invalid checkin_type: %', v_checkin_type;
  END IF;

  IF NOT public.team_checkin_is_right_local_time(v_local_time) THEN
    IF public.team_checkin_is_within_recovery_window(v_local_time)
       AND NOT public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'reminder') THEN
      v_is_recovery := true;
    ELSE
      RETURN jsonb_build_object('records_processed', 0,
        'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
    END IF;
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  v_dow := extract(dow FROM v_today)::int;

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';
  IF v_chat_id IS NULL THEN RAISE EXCEPTION 'telegram_team_group_chat_id not set'; END IF;

  IF v_checkin_type = 'morning' THEN
    v_text := E'🌅 Morning meeting in 5 minutes!\n\n';

    SELECT quote_text, attribution, video_url INTO v_quote
    FROM public.health_quotes
    WHERE agency_id = p_agency_id AND is_active = true AND pool = 'morning_motivation'
    ORDER BY random() LIMIT 1;
    IF v_quote.quote_text IS NOT NULL THEN
      v_text := v_text || '"' || v_quote.quote_text || '"';
      IF v_quote.attribution IS NOT NULL THEN
        v_text := v_text || ' — ' || v_quote.attribution;
      END IF;
      IF v_quote.video_url IS NOT NULL THEN
        v_text := v_text || E'\n▶️ ' || v_quote.video_url;
      END IF;
      v_text := v_text || E'\n\n';
    END IF;

    SELECT max(checkin_date) INTO v_last_eod_date
    FROM public.team_checkins
    WHERE agency_id = p_agency_id AND checkin_type = 'eod' AND checkin_date < v_today;

    IF v_last_eod_date IS NOT NULL THEN
      SELECT * INTO v_block FROM public.render_team_status_block(
        p_agency_id, v_last_eod_date, 'eod',
        format('📊 Last EOD (%s):', to_char(v_last_eod_date, 'Mon DD'))
      );
      v_text := v_text || v_block.block_text;
    ELSE
      v_text := v_text || E'(No prior EOD numbers on record yet.)';
    END IF;

  ELSIF v_checkin_type = 'midday' THEN
    v_text := E'☀️ Midday checkin!\n\n'
      || E'Quotes discussed this week / Sales points this quarter\n\n'
      || E'If someone''s busy, answer for them.';
  ELSE
    v_text := E'🌙 Daily Wrapup and EOD checkin!\n\n'
      || E'Quotes discussed this week / Sales points this quarter\n\n'
      || E'If someone''s busy, answer for them.';
  END IF;

  SELECT COUNT(*) INTO v_pending_votes
  FROM public.time_off_requests
  WHERE agency_id = p_agency_id
    AND status = 'voting'
    AND vote_closes_at > NOW();

  IF v_pending_votes > 0 THEN
    v_text := v_text || E'\n\n🗳️ Pending team votes: ' || v_pending_votes::text
      || ' — open Newtworks to weigh in.';
  END IF;

  IF v_checkin_type = 'morning' AND v_last_eod_date IS NOT NULL THEN
    v_text := v_text || E'\n\n━━━━━━━━━━━━━━━━━━━\n'
      || E'🏃 Move throughout the day. Get those steps in, take the stairs, '
      || E'and hit your exercise goal. We''ll check on the health goals at 7 PM.';
  END IF;

  IF v_checkin_type = 'eod' AND v_dow = 5 THEN
    v_text := v_text || E'\n\n━━━━━━━━━━━━━━━━━━━\n'
      || E'📝 Weekly wrapup — email to paper.newt.management@gmail.com:\n\n'
      || E'1. Attach your FIT Scorecard from this week.\n'
      || E'2. Main personal obstacle from this week.\n'
      || E'3. One goal for next week — 1% gain in sales points?\n'
      || E'4. One way to improve office efficiency?\n'
      || E'5. Brags for each teammate.\n\n'
      || E'━━━━━━━━━━━━━━━━━━━\n'
      || E'📬 And reply to Peter''s CPR email if you haven''t.';
  END IF;

  v_response := public.telegram_send_message(v_chat_id, v_text);
  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;
  v_message_id := (v_response->'result'->>'message_id')::bigint;

  INSERT INTO public.team_checkin_runs (
    agency_id, checkin_date, checkin_type,
    reminder_sent_at, reminder_message_id, reminder_text
  ) VALUES (
    p_agency_id, v_today, v_checkin_type,
    now(), v_message_id, v_text
  )
  ON CONFLICT (agency_id, checkin_date, checkin_type) DO UPDATE
    SET reminder_sent_at = EXCLUDED.reminder_sent_at,
        reminder_message_id = EXCLUDED.reminder_message_id,
        reminder_text = EXCLUDED.reminder_text,
        updated_at = now();

  RETURN jsonb_build_object('records_processed', 1,
    'output_summary', format('%s reminder sent%s (msg_id=%s, dow=%s, pending_votes=%s)',
      v_checkin_type, CASE WHEN v_is_recovery THEN ' [RECOVERY]' ELSE '' END,
      v_message_id, v_dow, v_pending_votes));
END;
$function$;

CREATE OR REPLACE FUNCTION public.time_off_calendar_dispatch(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
DECLARE
  v_events_created      int := 0;
  v_events_skipped      int := 0;
  v_event_ids_captured  int := 0;
  v_req RECORD;
  v_pg_net_id bigint;
  v_calendar_id text;
  v_calendar_name text;
  v_summary text;
  v_description text;
  v_description_base text;
  v_start_ts timestamptz;
  v_end_ts timestamptz;
  v_attendees text[];
  v_type_label text;
  v_event_id text;
  v_pg_net_ids bigint[];
  v_event_ids  text[];
  v_current_date date;
  v_app_url text := 'https://newtworks.vercel.app';
  v_cal_time_off text := '9b19aaadf951b1018ea03643a530030a44c6029be887426f892ae85fccfce156@group.calendar.google.com';
  v_cal_location text := 'ece83179e486bdfe5c7c736c7ccc7fec577ea25a8e46fe5c76a2dc25fb615c41@group.calendar.google.com';
BEGIN
  FOR v_req IN
    SELECT r.id, r.request_type, r.start_date, r.end_date, r.partial_day,
           r.notes, r.decision_note, r.proposed_four_day_off_day,
           r.is_paid, r.is_planned, r.requester_team_id,
           req_t.first_name, req_t.last_name, req_t.work_location,
           COALESCE(req_t.email_sf, req_t.email_personal) AS requester_email
    FROM public.time_off_requests r
    JOIN public.team req_t ON req_t.id = r.requester_team_id
    WHERE r.agency_id = p_agency_id
      AND r.status = 'approved'
      AND r.calendar_dispatched_at IS NULL
  LOOP
    IF v_req.request_type IN ('pto_full_day', 'pto_half_day', 'sick', 'four_day_off_change') THEN
      v_calendar_id := v_cal_time_off;
      v_calendar_name := 'Story Agency — Time Off';
      v_type_label := CASE v_req.request_type
        WHEN 'pto_full_day' THEN 'PTO'
        WHEN 'pto_half_day' THEN 'PTO (half day)'
        WHEN 'sick' THEN 'Sick'
        WHEN 'four_day_off_change' THEN '4-day off → ' || COALESCE(v_req.proposed_four_day_off_day, '?')
      END;
    ELSIF v_req.request_type IN ('remote_day', 'remote_half_day') THEN
      IF v_req.work_location = 'remote' THEN
        UPDATE public.time_off_requests
        SET calendar_dispatched_at = NOW(),
            calendar_name = '(skipped — requester is already default remote)'
        WHERE id = v_req.id;
        v_events_skipped := v_events_skipped + 1;
        CONTINUE;
      END IF;
      v_calendar_id := v_cal_location;
      v_calendar_name := 'Story Agency — Location';
      v_type_label := CASE v_req.request_type
        WHEN 'remote_day' THEN 'Remote'
        WHEN 'remote_half_day' THEN 'Remote (half day)'
      END;
    ELSE
      UPDATE public.time_off_requests
      SET calendar_dispatched_at = NOW(),
          calendar_name = '(skipped — unknown request_type: ' || v_req.request_type || ')'
      WHERE id = v_req.id;
      v_events_skipped := v_events_skipped + 1;
      CONTINUE;
    END IF;

    v_summary := v_req.first_name || ' — ' || v_type_label;
    v_description_base := 'Approved time off request' || E'\n\n' ||
                          'Type: ' || v_type_label || E'\n' ||
                          'When: ' || trim(to_char(v_req.start_date, 'Day, Month DD, YYYY'));
    IF v_req.start_date <> v_req.end_date THEN
      v_description_base := v_description_base || ' → ' || trim(to_char(v_req.end_date, 'Day, Month DD, YYYY'));
    END IF;
    IF v_req.is_paid IS NOT NULL THEN
      v_description_base := v_description_base || E'\nPay: ' || CASE WHEN v_req.is_paid THEN 'Paid' ELSE 'Unpaid' END;
    END IF;
    IF v_req.is_planned IS NOT NULL THEN
      v_description_base := v_description_base || E'\nPlanning: ' || CASE WHEN v_req.is_planned THEN 'Planned' ELSE 'Unplanned' END;
    END IF;
    IF v_req.notes IS NOT NULL THEN
      v_description_base := v_description_base || E'\n\nRequester notes: ' || v_req.notes;
    END IF;
    IF v_req.decision_note IS NOT NULL THEN
      v_description_base := v_description_base || E'\n\nApproval note: ' || v_req.decision_note;
    END IF;
    v_description_base := v_description_base || E'\n\nManaged via Newtworks: ' || v_app_url;

    v_attendees := CASE WHEN v_req.requester_email IS NOT NULL AND v_req.requester_email <> ''
                        THEN ARRAY[v_req.requester_email] ELSE ARRAY[]::text[] END;

    v_pg_net_ids := ARRAY[]::bigint[];

    IF v_req.partial_day = 'morning' THEN
      v_start_ts := (v_req.start_date::text || ' 08:30:00')::timestamp AT TIME ZONE 'America/Chicago';
      v_end_ts   := (v_req.start_date::text || ' 13:30:00')::timestamp AT TIME ZONE 'America/Chicago';
      v_pg_net_id := public.time_off_create_calendar_event(
        p_agency_id, v_calendar_id, v_summary, v_description_base, v_start_ts, v_end_ts, v_attendees);
      v_pg_net_ids := ARRAY[v_pg_net_id];
      v_events_created := v_events_created + 1;
    ELSIF v_req.partial_day = 'afternoon' THEN
      v_start_ts := (v_req.start_date::text || ' 12:30:00')::timestamp AT TIME ZONE 'America/Chicago';
      v_end_ts   := (v_req.start_date::text || ' 17:30:00')::timestamp AT TIME ZONE 'America/Chicago';
      v_pg_net_id := public.time_off_create_calendar_event(
        p_agency_id, v_calendar_id, v_summary, v_description_base, v_start_ts, v_end_ts, v_attendees);
      v_pg_net_ids := ARRAY[v_pg_net_id];
      v_events_created := v_events_created + 1;
    ELSE
      v_current_date := v_req.start_date;
      WHILE v_current_date <= v_req.end_date LOOP
        IF EXTRACT(DOW FROM v_current_date) BETWEEN 1 AND 5 THEN
          v_start_ts := (v_current_date::text || ' 08:30:00')::timestamp AT TIME ZONE 'America/Chicago';
          v_end_ts   := (v_current_date::text || ' 17:30:00')::timestamp AT TIME ZONE 'America/Chicago';
          v_pg_net_id := public.time_off_create_calendar_event(
            p_agency_id, v_calendar_id, v_summary, v_description_base, v_start_ts, v_end_ts, v_attendees);
          v_pg_net_ids := array_append(v_pg_net_ids, v_pg_net_id);
          v_events_created := v_events_created + 1;
        END IF;
        v_current_date := v_current_date + 1;
      END LOOP;
    END IF;

    UPDATE public.time_off_requests
    SET calendar_dispatched_at = NOW(),
        calendar_pg_net_request_id = v_pg_net_ids,
        calendar_name = v_calendar_name
    WHERE id = v_req.id;
  END LOOP;

  FOR v_req IN
    SELECT r.id, r.calendar_pg_net_request_id
    FROM public.time_off_requests r
    WHERE r.agency_id = p_agency_id
      AND r.calendar_pg_net_request_id IS NOT NULL
      AND (r.calendar_event_id IS NULL
           OR COALESCE(array_length(r.calendar_event_id, 1), 0)
              < COALESCE(array_length(r.calendar_pg_net_request_id, 1), 0))
      AND r.calendar_dispatched_at IS NOT NULL
      AND r.calendar_dispatched_at > NOW() - INTERVAL '48 hours'
  LOOP
    v_event_ids := ARRAY[]::text[];
    FOREACH v_pg_net_id IN ARRAY v_req.calendar_pg_net_request_id LOOP
      SELECT (resp.content::jsonb)#>>'{data,response_data,id}'
      INTO v_event_id
      FROM net._http_response resp
      WHERE resp.id = v_pg_net_id;
      IF v_event_id IS NOT NULL AND v_event_id <> '' THEN
        v_event_ids := array_append(v_event_ids, v_event_id);
      END IF;
    END LOOP;

    IF COALESCE(array_length(v_event_ids, 1), 0)
       = COALESCE(array_length(v_req.calendar_pg_net_request_id, 1), 0)
    THEN
      UPDATE public.time_off_requests
      SET calendar_event_id = v_event_ids
      WHERE id = v_req.id;
      v_event_ids_captured := v_event_ids_captured + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'events_created',     v_events_created,
    'events_skipped',     v_events_skipped,
    'event_ids_captured', v_event_ids_captured,
    'dispatched_at',      NOW()
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.time_off_notification_dispatch(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
DECLARE
  v_vote_request_emails int := 0;
  v_vote_closed_processed int := 0;
  v_decision_emails int := 0;
  v_req RECORD;
  v_voter RECORD;
  v_pg_net_id bigint;
  v_app_url text := 'https://newtworks.vercel.app';
  v_peter_email text;
  v_vote_status jsonb;
  v_html text;
  v_subject text;
  v_when_text text;
  v_token text;
BEGIN
  SELECT COALESCE(email_sf, email_personal) INTO v_peter_email
  FROM public.team
  WHERE agency_id = p_agency_id AND role_level = 'Owner' AND is_admin_backoffice = false AND archived_at IS NULL
  ORDER BY hire_date LIMIT 1;

  FOR v_req IN
    SELECT r.id, r.request_type, r.start_date, r.end_date, r.notes,
           r.requester_team_id,
           (req_t.first_name || ' ' || req_t.last_name) AS requester_name,
           r.vote_closes_at
    FROM public.time_off_requests r
    JOIN public.team req_t ON req_t.id = r.requester_team_id
    WHERE r.agency_id = p_agency_id
      AND r.status = 'voting'
      AND r.voters_notified_at IS NULL
  LOOP
    v_token := SUBSTRING(v_req.id::text, 1, 8);
    v_when_text := to_char(v_req.start_date, 'Dy, Mon DD');
    IF v_req.start_date <> v_req.end_date THEN
      v_when_text := v_when_text || ' through ' || to_char(v_req.end_date, 'Dy, Mon DD');
    END IF;
    v_subject := 'Vote needed: ' || v_req.requester_name || E'\'s time off request [#' || v_token || ']';

    FOR v_voter IN
      SELECT team_id AS id, first_name, last_name,
             COALESCE(email_sf, email_personal) AS email
      FROM public.get_expected_teammates(p_agency_id, 'work_checkin')
      WHERE team_id <> v_req.requester_team_id
        AND COALESCE(email_sf, email_personal) IS NOT NULL
    LOOP
      v_html :=
        '<p>Hi ' || v_voter.first_name || ',</p>' ||
        '<p><strong>' || v_req.requester_name || '</strong> has requested time off:</p>' ||
        '<ul>' ||
        '<li><strong>Type:</strong> ' || replace(v_req.request_type, '_', ' ') || '</li>' ||
        '<li><strong>When:</strong> ' || v_when_text || '</li>' ||
        CASE WHEN v_req.notes IS NOT NULL THEN '<li><strong>Notes:</strong> ' || v_req.notes || '</li>' ELSE '' END ||
        '</ul>' ||
        '<p>Voting closes <strong>' || to_char(v_req.vote_closes_at AT TIME ZONE 'America/Chicago', 'Dy Mon DD at HH12:MI AM') || ' CT</strong>.</p>' ||
        '<p><strong>Two ways to vote:</strong></p>' ||
        '<ol>' ||
        '<li><a href="' || v_app_url || '" style="color:#2563eb;font-weight:600;">Open Newtworks &rarr; Time Off</a></li>' ||
        '<li>Reply to this email with <strong>Yes</strong>, <strong>No</strong>, or <strong>Abstain</strong>. A sentence is welcome &mdash; it gets logged as your reason.</li>' ||
        '</ol>' ||
        '<p style="color:#64748b;font-size:13px;">If you don''t vote, it''s ok &mdash; Peter makes the final call regardless. ' ||
        'Keep the <code>[#' || v_token || ']</code> in the subject when you reply so the vote gets matched to the right request.</p>';

      v_pg_net_id := public.time_off_send_email(p_agency_id, v_voter.email, v_subject, v_html);
      INSERT INTO public.time_off_notification_log (agency_id, request_id, notification_type, recipient_email, subject, pg_net_request_id)
      VALUES (p_agency_id, v_req.id, 'vote_request', v_voter.email, v_subject, v_pg_net_id);
      v_vote_request_emails := v_vote_request_emails + 1;
    END LOOP;

    UPDATE public.time_off_requests SET voters_notified_at = NOW() WHERE id = v_req.id;
  END LOOP;

  FOR v_req IN
    SELECT r.id, r.request_type, r.start_date, r.end_date, r.notes,
           r.requester_team_id,
           (req_t.first_name || ' ' || req_t.last_name) AS requester_name
    FROM public.time_off_requests r
    JOIN public.team req_t ON req_t.id = r.requester_team_id
    WHERE r.agency_id = p_agency_id
      AND r.status = 'voting'
      AND r.vote_closes_at < NOW()
      AND r.vote_close_processed_at IS NULL
  LOOP
    v_vote_status := public.time_off_vote_status(v_req.id);
    UPDATE public.time_off_requests SET status = 'awaiting_decision', vote_close_processed_at = NOW() WHERE id = v_req.id;

    IF v_peter_email IS NOT NULL THEN
      v_when_text := to_char(v_req.start_date, 'Dy, Mon DD');
      IF v_req.start_date <> v_req.end_date THEN
        v_when_text := v_when_text || ' through ' || to_char(v_req.end_date, 'Dy, Mon DD');
      END IF;
      v_subject := 'Time off vote closed: ' || v_req.requester_name || E'\'s request awaits your decision';
      v_html :=
        '<p>Voting just closed on <strong>' || v_req.requester_name || '</strong>''s time off request:</p>' ||
        '<ul>' ||
        '<li><strong>Type:</strong> ' || replace(v_req.request_type, '_', ' ') || '</li>' ||
        '<li><strong>When:</strong> ' || v_when_text || '</li>' ||
        '<li><strong>Vote tally:</strong> &#128077; ' || COALESCE(v_vote_status->>'yes_count','0') ||
          ' &middot; &#128078; ' || COALESCE(v_vote_status->>'no_count','0') ||
          ' &middot; &mdash; ' || COALESCE(v_vote_status->>'abstain_count','0') ||
          ' &middot; &#9208; ' || COALESCE(v_vote_status->>'non_responder_count','0') || ' (no response)</li>' ||
        '<li><strong>Quorum:</strong> ' || CASE WHEN (v_vote_status->>'quorum_met')::boolean THEN 'met' ELSE 'NOT met' END || '</li>' ||
        '<li><strong>Recommendation:</strong> ' || REPLACE(COALESCE(v_vote_status->>'recommendation', '—'), '_', ' ') || '</li>' ||
        '</ul>' ||
        '<p><a href="' || v_app_url || '" style="display:inline-block;padding:10px 20px;background:#2563eb;color:#fff;text-decoration:none;border-radius:6px;font-weight:600;">Open Newtworks Inbox &rarr; decide</a></p>';

      v_pg_net_id := public.time_off_send_email(p_agency_id, v_peter_email, v_subject, v_html);
      INSERT INTO public.time_off_notification_log (agency_id, request_id, notification_type, recipient_email, subject, pg_net_request_id)
      VALUES (p_agency_id, v_req.id, 'vote_closed', v_peter_email, v_subject, v_pg_net_id);
    END IF;
    v_vote_closed_processed := v_vote_closed_processed + 1;
  END LOOP;

  FOR v_req IN
    SELECT r.id, r.request_type, r.start_date, r.end_date, r.status, r.decision_note,
           r.requester_team_id,
           (req_t.first_name || ' ' || req_t.last_name) AS requester_name,
           req_t.first_name AS requester_first_name,
           COALESCE(req_t.email_sf, req_t.email_personal) AS requester_email
    FROM public.time_off_requests r
    JOIN public.team req_t ON req_t.id = r.requester_team_id
    WHERE r.agency_id = p_agency_id
      AND r.status IN ('approved', 'denied')
      AND r.decision_notified_at IS NULL
  LOOP
    v_when_text := to_char(v_req.start_date, 'Dy, Mon DD');
    IF v_req.start_date <> v_req.end_date THEN
      v_when_text := v_when_text || ' through ' || to_char(v_req.end_date, 'Dy, Mon DD');
    END IF;

    IF v_req.requester_email IS NOT NULL THEN
      v_subject := 'Time off ' || v_req.status || ': your request';
      v_html :=
        '<p>Hi ' || v_req.requester_first_name || ',</p>' ||
        '<p>Your time off request has been <strong>' || UPPER(v_req.status) || '</strong>:</p>' ||
        '<ul>' ||
        '<li><strong>Type:</strong> ' || replace(v_req.request_type, '_', ' ') || '</li>' ||
        '<li><strong>When:</strong> ' || v_when_text || '</li>' ||
        CASE WHEN v_req.decision_note IS NOT NULL THEN '<li><strong>Note from Peter:</strong> ' || v_req.decision_note || '</li>' ELSE '' END ||
        '</ul>' ||
        '<p>This is also in Newtworks &rarr; Time Off &rarr; My Requests.</p>';
      v_pg_net_id := public.time_off_send_email(p_agency_id, v_req.requester_email, v_subject, v_html);
      INSERT INTO public.time_off_notification_log (agency_id, request_id, notification_type, recipient_email, subject, pg_net_request_id)
      VALUES (p_agency_id, v_req.id, 'decision_requester', v_req.requester_email, v_subject, v_pg_net_id);
    END IF;

    FOR v_voter IN
      SELECT first_name, COALESCE(email_sf, email_personal) AS email
      FROM public.get_expected_teammates(p_agency_id, 'work_checkin')
      WHERE team_id <> v_req.requester_team_id
        AND COALESCE(email_sf, email_personal) IS NOT NULL
    LOOP
      v_subject := 'Time off ' || v_req.status || ': ' || v_req.requester_name || E'\'s request';
      v_html :=
        '<p>Hi ' || v_voter.first_name || ',</p>' ||
        '<p><strong>' || v_req.requester_name || '</strong>''s time off request was <strong>' || UPPER(v_req.status) || '</strong>: ' || v_when_text || '.</p>';
      v_pg_net_id := public.time_off_send_email(p_agency_id, v_voter.email, v_subject, v_html);
      INSERT INTO public.time_off_notification_log (agency_id, request_id, notification_type, recipient_email, subject, pg_net_request_id)
      VALUES (p_agency_id, v_req.id, 'decision_team', v_voter.email, v_subject, v_pg_net_id);
      v_decision_emails := v_decision_emails + 1;
    END LOOP;

    UPDATE public.time_off_requests SET decision_notified_at = NOW() WHERE id = v_req.id;
  END LOOP;

  RETURN jsonb_build_object(
    'vote_request_emails', v_vote_request_emails,
    'vote_closed_processed', v_vote_closed_processed,
    'decision_emails', v_decision_emails,
    'dispatched_at', NOW()
  );
END;
$function$;

CREATE OR REPLACE VIEW public.v_balance_sheet_anchored AS
 WITH agency AS (
         SELECT '126794dd-25ff-47d2-a436-724499733365'::uuid AS id
        ), post_activity AS (
         SELECT coa.account_code,
            max(coa.account_name) AS account_name,
            coa.account_type,
            round(sum(
                CASE
                    WHEN coa.account_type = ANY (ARRAY['asset'::text, 'expense'::text]) THEN jl.debit - jl.credit
                    ELSE jl.credit - jl.debit
                END), 2) AS activity
           FROM journal_entries je
             JOIN journal_lines jl ON jl.journal_entry_id = je.id
             JOIN chart_of_accounts coa ON coa.id = jl.account_id,
            agency
          WHERE je.agency_id = agency.id AND je.entry_date > '2026-04-30'::date AND (coa.account_type = ANY (ARRAY['asset'::text, 'liability'::text, 'equity'::text]))
          GROUP BY coa.account_code, coa.account_type
        ), post_net_income AS (
         SELECT round(sum(
                CASE
                    WHEN coa.account_type = 'income'::text THEN jl.credit - jl.debit
                    WHEN coa.account_type = 'expense'::text THEN - (jl.debit - jl.credit)
                    ELSE 0::numeric
                END), 2) AS ni
           FROM journal_entries je
             JOIN journal_lines jl ON jl.journal_entry_id = je.id
             JOIN chart_of_accounts coa ON coa.id = jl.account_id,
            agency
          WHERE je.agency_id = agency.id AND je.entry_date > '2026-04-30'::date AND (coa.account_type = ANY (ARRAY['income'::text, 'expense'::text]))
        ), codes AS (
         SELECT opening_balances.account_code
           FROM opening_balances,
            agency
          WHERE opening_balances.agency_id = agency.id AND opening_balances.as_of_date = '2026-04-30'::date
        UNION
         SELECT post_activity.account_code
           FROM post_activity
        )
 SELECT agency.id AS agency_id,
    c.account_code,
    COALESCE(ob.account_name, pa.account_name) AS account_name,
    COALESCE(ob.account_type, pa.account_type) AS account_type,
    COALESCE(ob.opening_balance, 0::numeric) AS anchor_0430,
    COALESCE(pa.activity, 0::numeric) AS activity_since_0430,
    round(COALESCE(ob.opening_balance, 0::numeric) + COALESCE(pa.activity, 0::numeric), 2) AS balance_current
   FROM codes c
     CROSS JOIN agency
     LEFT JOIN opening_balances ob ON ob.account_code = c.account_code AND ob.agency_id = agency.id AND ob.as_of_date = '2026-04-30'::date
     LEFT JOIN post_activity pa ON pa.account_code = c.account_code
UNION ALL
 SELECT agency.id AS agency_id,
    'NI-POST0430'::text AS account_code,
    'Net Income (May 1 forward)'::text AS account_name,
    'equity'::text AS account_type,
    0::numeric AS anchor_0430,
    COALESCE(( SELECT post_net_income.ni
           FROM post_net_income), 0::numeric) AS activity_since_0430,
    COALESCE(( SELECT post_net_income.ni
           FROM post_net_income), 0::numeric) AS balance_current
   FROM agency;

UPDATE public.automation_recipes
SET recipe_description = 'Daily at 9am CDT: checks v_bank_register_coding_questions for any unresolved items. If any exist, emails Peter with a plain-English question for each transaction. Peter replies or codes in Newtworks. No GL entries are written for uncoded transactions.'
WHERE recipe_name = 'Transaction Coding Question Mailer';
