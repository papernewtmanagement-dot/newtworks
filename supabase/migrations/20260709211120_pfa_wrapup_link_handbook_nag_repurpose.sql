-- 1) Handbook: expand the "Final deposit" line in Daily Wrap-up
UPDATE public.manuals
SET
  content = REPLACE(
    content,
    E'\n\nFinal deposit completed and emailed to the agent — *team*\n\n',
    E'\n\n<details>\n<summary>Final deposit completed — <em>team</em></summary>\n\n'
      || E'At the end of the day, consolidate every customer premium payment received today (cash, checks, transfers) and take it to the Frost drive-through or mobile-deposit it.\n\n'
      || E'Log each of those payments the same day in **Sidebar → PFA → Record deposit** — first name + last initial only, policy type, amount, and check number if applicable.\n\n'
      || E'That''s it. Peter is notified automatically and Newtworks handles the monthly reconciliation to SF.\n\n'
      || E'</details>\n\n'
  ),
  version = version + 1,
  updated_at = now()
WHERE id = 'e427ccf0-1907-4b6a-8e7a-3e9376f3ac7b'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 2) EOD reminder: add PFA link (every EOD, all weekdays, HTML mode)
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
  v_calls_block text;
  v_pending_votes int;
  v_is_recovery boolean := false;
  v_parse_mode text := NULL;
  v_fit_url text := 'https://newtworks.vercel.app/handbook/newtworks-native-glossary-fit';
  v_pfa_url text := 'https://newtworks.vercel.app/pfa';
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
    v_text := E'🌅 Kickoff in 5!\n\n';

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
        format('📊 EOD %s', to_char(v_last_eod_date, 'Mon DD'))
      );
      v_text := v_text || v_block.block_text;
    ELSE
      v_text := v_text || E'(No prior EOD numbers on record yet.)';
    END IF;

    v_calls_block := public.render_daily_calls_block(p_agency_id, v_today - 1);
    IF v_calls_block IS NULL OR v_calls_block = '' THEN
      v_calls_block := public.render_daily_calls_block(p_agency_id, v_today - 2);
    END IF;
    IF v_calls_block IS NOT NULL AND v_calls_block <> '' THEN
      v_text := v_text || E'\n' || v_calls_block;
    END IF;

    IF v_last_eod_date IS NOT NULL AND v_block.encouragement_text IS NOT NULL THEN
      v_text := v_text || E'\n' || v_block.encouragement_text;
    END IF;

  ELSIF v_checkin_type = 'midday' THEN
    v_text := E'☀️ Midday\n\n'
      || E'Quotes this week / SP this quarter\n\n'
      || E'If someone''s busy, answer for them.';
  ELSE
    v_text := E'🌙 EOD\n\n'
      || E'Quotes this week / SP this quarter\n\n'
      || E'If someone''s busy, answer for them.';
  END IF;

  SELECT COUNT(*) INTO v_pending_votes
  FROM public.time_off_requests
  WHERE agency_id = p_agency_id
    AND status = 'voting'
    AND vote_closes_at > NOW();

  IF v_pending_votes > 0 THEN
    v_text := v_text || E'\n\n🗳️ ' || v_pending_votes::text;
  END IF;

  IF v_checkin_type = 'morning' AND v_last_eod_date IS NOT NULL THEN
    v_text := v_text || E'\n\n━━━━━━━━━━━━━━━━━━━\n'
      || E'🏃 Move throughout the day. Get those steps in, take the stairs, '
      || E'and hit your exercise goal. We''ll check on the health goals at 7 PM.';
  END IF;

  -- NEW (2026-07-09): PFA reminder on every EOD (all weekdays). HTML mode.
  IF v_checkin_type = 'eod' THEN
    v_parse_mode := 'HTML';
    v_text := v_text || E'\n\n━━━━━━━━━━━━━━━━━━━\n'
      || E'💰 <a href="' || v_pfa_url || E'">Don''t forget deposit records</a>';
  END IF;

  IF v_checkin_type = 'eod' AND v_dow = 5 THEN
    v_parse_mode := 'HTML';
    v_text := v_text || E'\n\n━━━━━━━━━━━━━━━━━━━\n'
      || E'📝 Weekly wrapup — email paper.newt.management@gmail.com:\n\n'
      || E'1. Remember <a href="' || v_fit_url || E'">FIT Scorecard</a>.\n'
      || E'2. Main obstacle this week.\n'
      || E'3. One goal next week — 1% SP gain?\n'
      || E'4. One office efficiency idea?\n'
      || E'5. Brags for each teammate.\n\n'
      || E'━━━━━━━━━━━━━━━━━━━\n'
      || E'📬 Reply to Peter''s CPR email if you haven''t.';
  END IF;

  v_response := public.telegram_send_message(v_chat_id, v_text, v_parse_mode);
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

-- 3) Repurpose pfa_monthly_nag
CREATE OR REPLACE FUNCTION public.pfa_monthly_nag(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_stmt_end_date     date := (date_trunc('month', current_date) - interval '1 day')::date;
  v_month_key         text := to_char(v_stmt_end_date, 'YYYY-MM');
  v_month_name        text := to_char(v_stmt_end_date, 'FMMonth YYYY');
  v_mod_ref           text := 'pfa_statement_ingest:' || v_month_key;
  v_due_date          date := (date_trunc('month', current_date) + interval '9 days')::date;
  v_existing_alert_id uuid;
  v_statement_id      uuid;
  v_peter_tg          bigint;
  v_tg_resp           jsonb;
  v_dm_text           text;
  v_action_taken      text;
BEGIN
  SELECT ttm.telegram_user_id INTO v_peter_tg
  FROM public.team_telegram_map ttm
  JOIN public.team t ON t.id = ttm.team_id
  WHERE t.first_name='Peter' AND t.last_name='Story' LIMIT 1;
  v_peter_tg := COALESCE(v_peter_tg, 7778113542);

  SELECT id INTO v_statement_id
  FROM public.pfa_bank_statements
  WHERE agency_id = p_agency_id
    AND statement_ending_date = v_stmt_end_date
  LIMIT 1;

  SELECT id INTO v_existing_alert_id
  FROM public.alerts
  WHERE agency_id = p_agency_id
    AND module_reference = v_mod_ref
    AND COALESCE(is_resolved, false) = false
  LIMIT 1;

  IF v_statement_id IS NOT NULL THEN
    IF v_existing_alert_id IS NOT NULL THEN
      UPDATE public.alerts
      SET is_resolved = true, resolved_at = now()
      WHERE id = v_existing_alert_id;
      RETURN jsonb_build_object(
        'records_processed', 1,
        'output_summary', format('Statement %s ingested; alert auto-resolved.', v_month_key),
        'month', v_month_key, 'statement_id', v_statement_id
      );
    END IF;
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary', format('Statement %s ingested; no alert to resolve.', v_month_key)
    );
  END IF;

  IF v_existing_alert_id IS NULL THEN
    IF extract(day from current_date) <= 10 THEN
      INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved, due_date, created_at)
      VALUES (p_agency_id, 'pfa_statement_ingest', 'warning',
        format('Send Frost PFA statement for %s', v_month_name),
        format('Forward the Frost Bank PFA statement PDF for %s to paper.newt.management@gmail.com. Newtworks will auto-reconcile and email SF. This alert auto-resolves when the statement lands.', v_month_name),
        v_mod_ref, false, false, v_due_date, now());
      v_action_taken := 'alert_created_and_dm_sent';
    ELSE
      RETURN jsonb_build_object('records_processed', 0,
        'output_summary', format('No statement for %s and past day 10; skipping.', v_month_key));
    END IF;
  ELSE
    v_action_taken := 'dm_resent';
  END IF;

  v_dm_text := format(
    E'📄 PFA statement reminder\n\nThe Frost Bank PFA statement for %s hasn''t been received yet. Forward the statement PDF to paper.newt.management@gmail.com.\n\nOnce ingested, Newtworks auto-reconciles and emails the printout to SF. This alert auto-resolves when the statement lands.',
    v_month_name);
  v_tg_resp := public.telegram_send_message_v2(v_peter_tg, v_dm_text, 'paper_newt');

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format('%s for PFA statement %s. Telegram DM ok=%s',
      v_action_taken, v_month_key, COALESCE((v_tg_resp->>'ok')::text, 'unknown')),
    'month', v_month_key, 'due_date', v_due_date, 'telegram_response', v_tg_resp
  );
END;
$function$;

-- 4) Retire old workflow alerts
UPDATE public.alerts
SET is_resolved = true, resolved_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND module_reference LIKE 'pfa_submission:%'
  AND COALESCE(is_resolved, false) = false;

-- Update recipe description
UPDATE public.automation_recipes
SET recipe_description = 'Daily 7am CT: if the previous-month Frost PFA statement is not yet in pfa_bank_statements, DM Peter to forward it to paper.newt.management@gmail.com. Auto-resolves once the statement is ingested.',
    updated_at = now()
WHERE id = 'ded3bf47-db47-45b5-b2a4-7aaf06f3adff';

