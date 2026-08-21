-- FIX A: time_off_calendar_dispatch — use real work hours (8:30 AM - 5:30 PM CT, noon-1 lunch)
-- Was: full-day events span midnight to next-midnight, half-day morning 08:00-12:00, afternoon 13:00-17:00.
-- Now:  full-day  = 08:30 to 17:30 same day (single event, lunch included for simplicity)
--       morning   = 08:30 to 12:00
--       afternoon = 13:00 to 17:30
--       multi-day full = 08:30 start_date to 17:30 end_date (one spanning event)
CREATE OR REPLACE FUNCTION public.time_off_calendar_dispatch(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'net'
AS $function$
DECLARE
  v_events_created int := 0;
  v_events_skipped int := 0;
  v_req RECORD;
  v_pg_net_id bigint;
  v_calendar_id text;
  v_calendar_name text;
  v_summary text;
  v_description text;
  v_start_ts timestamptz;
  v_end_ts timestamptz;
  v_attendees text[];
  v_type_label text;
  v_bcc_url text := 'https://storybccdashboard.vercel.app';
  v_cal_time_off text := '9b19aaadf951b1018ea03643a530030a44c6029be887426f892ae85fccfce156@group.calendar.google.com';
  v_cal_location text := 'ece83179e486bdfe5c7c736c7ccc7fec577ea25a8e46fe5c76a2dc25fb615c41@group.calendar.google.com';
BEGIN
  FOR v_req IN
    SELECT r.id, r.request_type, r.start_date, r.end_date, r.partial_day,
           r.notes, r.decision_note, r.proposed_four_day_off_day,
           r.requester_team_id,
           req_t.first_name, req_t.last_name, req_t.work_location,
           COALESCE(req_t.email_sf, req_t.email_personal) AS requester_email
    FROM public.time_off_requests r
    JOIN public.team req_t ON req_t.id = r.requester_team_id
    WHERE r.agency_id = p_agency_id
      AND r.status = 'approved'
      AND r.calendar_dispatched_at IS NULL
  LOOP
    -- Calendar routing
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

    v_description := 'Approved time off request' || E'\n\n' ||
                     'Type: ' || v_type_label || E'\n' ||
                     'When: ' || trim(to_char(v_req.start_date, 'Day, Month DD, YYYY'));
    IF v_req.start_date <> v_req.end_date THEN
      v_description := v_description || ' → ' || trim(to_char(v_req.end_date, 'Day, Month DD, YYYY'));
    END IF;
    IF v_req.notes IS NOT NULL THEN
      v_description := v_description || E'\n\nRequester notes: ' || v_req.notes;
    END IF;
    IF v_req.decision_note IS NOT NULL THEN
      v_description := v_description || E'\n\nApproval note: ' || v_req.decision_note;
    END IF;
    v_description := v_description || E'\n\nManaged via BCC: ' || v_bcc_url;

    -- Datetime ranges — work hours (8:30 AM to 5:30 PM CT, noon-1 PM lunch)
    IF v_req.partial_day = 'morning' THEN
      v_start_ts := (v_req.start_date::text || ' 08:30:00')::timestamp AT TIME ZONE 'America/Chicago';
      v_end_ts   := (v_req.start_date::text || ' 12:00:00')::timestamp AT TIME ZONE 'America/Chicago';
    ELSIF v_req.partial_day = 'afternoon' THEN
      v_start_ts := (v_req.start_date::text || ' 13:00:00')::timestamp AT TIME ZONE 'America/Chicago';
      v_end_ts   := (v_req.start_date::text || ' 17:30:00')::timestamp AT TIME ZONE 'America/Chicago';
    ELSE
      -- Full day (single or multi): 8:30 AM start_date → 5:30 PM end_date
      v_start_ts := (v_req.start_date::text || ' 08:30:00')::timestamp AT TIME ZONE 'America/Chicago';
      v_end_ts   := (v_req.end_date::text   || ' 17:30:00')::timestamp AT TIME ZONE 'America/Chicago';
    END IF;

    v_attendees := CASE WHEN v_req.requester_email IS NOT NULL AND v_req.requester_email <> ''
                        THEN ARRAY[v_req.requester_email]
                        ELSE ARRAY[]::text[] END;

    v_pg_net_id := public.time_off_create_calendar_event(
      p_agency_id, v_calendar_id, v_summary, v_description,
      v_start_ts, v_end_ts, v_attendees
    );

    UPDATE public.time_off_requests
    SET calendar_dispatched_at = NOW(),
        calendar_pg_net_request_id = v_pg_net_id,
        calendar_name = v_calendar_name
    WHERE id = v_req.id;

    v_events_created := v_events_created + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'events_created', v_events_created,
    'events_skipped', v_events_skipped,
    'dispatched_at', NOW()
  );
END;
$function$;

-- FIX B: team_checkin_send_reminder — add Pending Team Votes line to all three checkins.
-- Computed once, injected after the type-specific content, before any morning-specific health footer.
CREATE OR REPLACE FUNCTION public.team_checkin_send_reminder(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
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
  v_per_person text;
  v_last_eod_date date;
  v_total_q numeric;
  v_total_s numeric;
  v_wtw record;
  v_q_pass boolean;
  v_sp_pass boolean;
  v_q_short int;
  v_sp_short numeric;
  v_encouragement text;
  v_pending_votes int;
  v_pool_both_clear text[] := ARRAY[
    'Both conditions clear. That''s a Win the Week if it holds.',
    'Team''s running its own pace — quotes and SP both ahead. Keep stacking.',
    'On track on both. Don''t let the foot off the gas.'
  ];
  v_pool_quotes_pass_sp_behind text[] := ARRAY[
    'Quotes are flowing — now turn them into closes. The conversation''s happening, the conversion''s the gap.',
    'Activity strong, conversion needs love. Focus the close work.',
    'Plenty of at-bats. Time to drive a few in.'
  ];
  v_pool_sp_pass_quotes_behind text[] := ARRAY[
    'Closes are landing without the activity volume — efficient, but the pipeline thins fast. Feed it with quotes.',
    'SP looks great. Light quotes mean a leaner next week — push the conversations.',
    'Hitting on quality. Now widen the funnel before next week notices.'
  ];
  v_pool_both_behind text[] := ARRAY[
    'Real ground to make up on both. The week''s not done — push the rest hard.',
    'Behind on both. Today and tomorrow are where the week gets won.',
    'Both conditions still open. One conversation can start a streak.'
  ];
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_checkin_type := v_input_config->>'checkin_type';
  v_local_time := v_input_config->>'local_time';

  IF v_checkin_type NOT IN ('morning', 'midday', 'eod') THEN
    RAISE EXCEPTION 'Invalid checkin_type: %', v_checkin_type;
  END IF;

  IF NOT public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
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
      SELECT
        string_agg(
          format('• %s: %s/%s',
            COALESCE(NULLIF(t.nickname, ''), t.first_name),
            COALESCE(tc.quotes_week::text, '—'),
            COALESCE(to_char(tc.sales_points_quarter, 'FM999G999G999'), '—')),
          E'\n' ORDER BY t.first_name),
        COALESCE(SUM(tc.quotes_week), 0),
        COALESCE(SUM(tc.sales_points_quarter), 0)
      INTO v_per_person, v_total_q, v_total_s
      FROM public.team_checkins tc
      JOIN public.team t ON t.id = tc.team_id
      WHERE tc.agency_id = p_agency_id
        AND tc.checkin_date = v_last_eod_date
        AND tc.checkin_type = 'eod';

      v_text := v_text || format('📊 Last EOD (%s):', to_char(v_last_eod_date, 'Mon DD')) || E'\n';
      IF v_per_person IS NOT NULL THEN
        v_text := v_text || v_per_person || E'\n';
      END IF;
      v_text := v_text || format('Team total: %s/%s', v_total_q::text, to_char(v_total_s, 'FM999G999G999'));

      SELECT * INTO v_wtw FROM public.get_win_the_week_state(p_agency_id, v_last_eod_date);
      v_q_pass := v_total_q >= v_wtw.quotes_target_total;
      v_sp_pass := v_total_s >= v_wtw.sp_target;
      v_q_short := GREATEST(0, v_wtw.quotes_target_total - v_total_q::int);
      v_sp_short := GREATEST(0, v_wtw.sp_target - v_total_s);

      v_text := v_text || E'\n\n📈 Win the Week — Week ' || v_wtw.week_of_cycle
        || ' of 13 (ends ' || to_char(v_wtw.week_ending_saturday, 'Dy Mon DD') || E')\n';

      v_text := v_text || '  Quotes: ' || v_total_q::text || ' of ' || v_wtw.quotes_target_total::text;
      IF v_q_pass THEN v_text := v_text || '  ✅ cleared';
      ELSE v_text := v_text || '  —  ' || v_q_short::text || ' to clear';
      END IF;
      IF v_wtw.quotes_carryover > 0 THEN
        v_text := v_text || ' (carryover: ' || v_wtw.quotes_carryover::text || ' from prior week)';
      END IF;
      v_text := v_text || E'\n';

      v_text := v_text || '  SP pace: ' || to_char(v_total_s, 'FM999G999G999')
        || ' of ' || to_char(v_wtw.sp_target, 'FM999G999G999');
      IF v_sp_pass THEN v_text := v_text || '  ✅ cleared';
      ELSE v_text := v_text || '  —  ' || to_char(v_sp_short, 'FM999G999G999') || ' to clear';
      END IF;

      IF v_q_pass AND v_sp_pass THEN
        v_encouragement := v_pool_both_clear[1 + floor(random() * array_length(v_pool_both_clear, 1))::int];
      ELSIF v_q_pass AND NOT v_sp_pass THEN
        v_encouragement := v_pool_quotes_pass_sp_behind[1 + floor(random() * array_length(v_pool_quotes_pass_sp_behind, 1))::int];
      ELSIF v_sp_pass AND NOT v_q_pass THEN
        v_encouragement := v_pool_sp_pass_quotes_behind[1 + floor(random() * array_length(v_pool_sp_pass_quotes_behind, 1))::int];
      ELSE
        v_encouragement := v_pool_both_behind[1 + floor(random() * array_length(v_pool_both_behind, 1))::int];
      END IF;
      v_text := v_text || E'\n\n' || v_encouragement;
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

  -- Inject Pending Team Votes line if any open vote windows
  SELECT COUNT(*) INTO v_pending_votes
  FROM public.time_off_requests
  WHERE agency_id = p_agency_id
    AND status = 'voting'
    AND vote_closes_at > NOW();

  IF v_pending_votes > 0 THEN
    v_text := v_text || E'\n\n🗳️ Pending team votes: ' || v_pending_votes::text
      || ' — open BCC to weigh in.';
  END IF;

  -- Morning-only health/move footer (moved here so it stays the very last line)
  IF v_checkin_type = 'morning' AND v_last_eod_date IS NOT NULL THEN
    v_text := v_text || E'\n\n━━━━━━━━━━━━━━━━━━━\n'
      || E'🏃 Move throughout the day. Get those steps in, take the stairs, '
      || E'and hit your exercise goal. We''ll check on the health goals at 7 PM.';
  END IF;

  -- Friday EOD wrapup append (unchanged)
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
    'output_summary', format('%s reminder sent (msg_id=%s, dow=%s, pending_votes=%s)',
      v_checkin_type, v_message_id, v_dow, v_pending_votes));
END;
$function$;
