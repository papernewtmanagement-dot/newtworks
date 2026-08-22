-- =====================================================================
-- Leslie Monthly Goals Check-in Pipeline
-- Fires 8am CST on 1st of each month.
-- Bot posts in Paper Newt Management group (chat_id -5518666399) tagging Marie
-- via <a href="tg://user?id=...">Alvi</a> mention. Marie replies. Trigger captures her reply.
-- =====================================================================

-- 1. Table for each monthly checkin
CREATE TABLE IF NOT EXISTS public.leslie_monthly_checkin (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id UUID NOT NULL,
  review_month DATE NOT NULL,           -- 1st of the month being reviewed (e.g. 2026-07-01 for July)
  sent_at TIMESTAMPTZ,
  sent_message_id BIGINT,               -- Telegram message_id of the bot's send
  sent_ok BOOLEAN,
  sent_response JSONB,
  marie_reply_text TEXT,
  marie_reply_at TIMESTAMPTZ,
  marie_reply_message_id BIGINT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT leslie_monthly_checkin_unique_review UNIQUE (agency_id, review_month)
);

CREATE INDEX IF NOT EXISTS idx_leslie_monthly_checkin_open
  ON public.leslie_monthly_checkin (agency_id, sent_at)
  WHERE marie_reply_text IS NULL AND sent_at IS NOT NULL;

-- 2. Handler function — signature required by run_internal_recipe(agency_id, recipe_id) → jsonb
CREATE OR REPLACE FUNCTION public.leslie_monthly_goals_send(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','extensions'
AS $fn$
DECLARE
  v_group_chat_id BIGINT;
  v_review_month DATE;
  v_month_label TEXT;
  v_marie_user_id BIGINT;
  v_mention TEXT;
  v_message TEXT;
  v_resp JSONB;
  v_row_id UUID;
  v_message_id BIGINT;
  v_ok BOOLEAN;
BEGIN
  -- Group chat id from settings
  SELECT setting_value::bigint INTO v_group_chat_id
  FROM public.settings
  WHERE agency_id = p_agency_id
    AND setting_key = 'paper_newt_management_group_chat_id';

  IF v_group_chat_id IS NULL THEN
    RAISE EXCEPTION 'paper_newt_management_group_chat_id not set';
  END IF;

  -- Prior month: 1st of the month before today's month
  v_review_month := date_trunc('month', (NOW() AT TIME ZONE 'America/Chicago' - INTERVAL '1 day'))::date;
  v_month_label := to_char(v_review_month, 'FMMonth YYYY');

  -- Marie's Telegram user_id from map, if present. Optional — if missing, message uses plain name.
  SELECT ttm.telegram_user_id INTO v_marie_user_id
  FROM public.team_telegram_map ttm
  WHERE ttm.agency_id = p_agency_id
    AND ttm.team_id = 'd7431075-d29f-4833-9503-430945894b04'
    AND COALESCE(ttm.is_excluded, false) = false
  LIMIT 1;

  IF v_marie_user_id IS NOT NULL THEN
    v_mention := format('<a href="tg://user?id=%s">Alvi</a>', v_marie_user_id);
  ELSE
    v_mention := 'Alvi';
  END IF;

  v_message := format(
    E'%s — did Leslie hit her goals in %s? Reply here.',
    v_mention, v_month_label
  );

  -- Idempotent upsert of the checkin row BEFORE sending, so we always have a target for reply capture
  INSERT INTO public.leslie_monthly_checkin (agency_id, review_month)
  VALUES (p_agency_id, v_review_month)
  ON CONFLICT (agency_id, review_month) DO NOTHING
  RETURNING id INTO v_row_id;

  IF v_row_id IS NULL THEN
    SELECT id INTO v_row_id
    FROM public.leslie_monthly_checkin
    WHERE agency_id = p_agency_id AND review_month = v_review_month;
  END IF;

  -- If already sent + already replied, skip
  IF EXISTS (
    SELECT 1 FROM public.leslie_monthly_checkin
    WHERE id = v_row_id AND sent_at IS NOT NULL AND marie_reply_text IS NOT NULL
  ) THEN
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary', format('Already complete for %s — skipped', v_month_label)
    );
  END IF;

  -- Send via paper_newt_bot with HTML parse mode (for the user mention)
  v_resp := public.paper_newt_send_message(v_group_chat_id, v_message, 'HTML', NULL);

  v_ok := COALESCE((v_resp->>'ok')::boolean, false);
  v_message_id := NULLIF((v_resp #>> '{result,message_id}'), '')::bigint;

  UPDATE public.leslie_monthly_checkin
  SET sent_at = NOW(),
      sent_ok = v_ok,
      sent_response = v_resp,
      sent_message_id = v_message_id,
      updated_at = NOW()
  WHERE id = v_row_id;

  IF NOT v_ok THEN
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary', format('Send failed for %s: %s', v_month_label, v_resp->>'error')
    );
  END IF;

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format('Sent Leslie goals check-in for %s (msg_id %s)', v_month_label, v_message_id)
  );
END;
$fn$;

-- 3. Reply-capture trigger on chatbot_messages
CREATE OR REPLACE FUNCTION public.leslie_monthly_capture_reply()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $trg$
DECLARE
  v_chat_id BIGINT;
  v_group_chat_id BIGINT;
  v_marie_team_id UUID := 'd7431075-d29f-4833-9503-430945894b04';
  v_speaker_team_id UUID;
  v_row_id UUID;
BEGIN
  -- Only user turns with a real speaker qualify
  IF NEW.role <> 'user' OR NEW.speaker_telegram_user_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Resolve the chat_id from the conversation
  SELECT cc.telegram_chat_id INTO v_chat_id
  FROM public.chatbot_conversations cc
  WHERE cc.id = NEW.conversation_id;

  IF v_chat_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Get the configured group chat_id
  SELECT setting_value::bigint INTO v_group_chat_id
  FROM public.settings
  WHERE agency_id = NEW.agency_id
    AND setting_key = 'paper_newt_management_group_chat_id';

  IF v_group_chat_id IS NULL OR v_chat_id <> v_group_chat_id THEN
    RETURN NEW;
  END IF;

  -- Is the speaker Marie?
  SELECT ttm.team_id INTO v_speaker_team_id
  FROM public.team_telegram_map ttm
  WHERE ttm.agency_id = NEW.agency_id
    AND ttm.telegram_user_id = NEW.speaker_telegram_user_id;

  IF v_speaker_team_id IS DISTINCT FROM v_marie_team_id THEN
    RETURN NEW;
  END IF;

  -- Find the most recent open (sent but not replied) checkin and fill it
  SELECT id INTO v_row_id
  FROM public.leslie_monthly_checkin
  WHERE agency_id = NEW.agency_id
    AND sent_at IS NOT NULL
    AND sent_at < NEW.created_at
    AND marie_reply_text IS NULL
  ORDER BY sent_at DESC
  LIMIT 1;

  IF v_row_id IS NULL THEN
    RETURN NEW;
  END IF;

  UPDATE public.leslie_monthly_checkin
  SET marie_reply_text = NEW.content,
      marie_reply_at = NEW.created_at,
      marie_reply_message_id = NEW.telegram_message_id,
      updated_at = NOW()
  WHERE id = v_row_id;

  RETURN NEW;
END;
$trg$;

DROP TRIGGER IF EXISTS trg_leslie_capture_reply ON public.chatbot_messages;
CREATE TRIGGER trg_leslie_capture_reply
AFTER INSERT ON public.chatbot_messages
FOR EACH ROW
EXECUTE FUNCTION public.leslie_monthly_capture_reply();

-- 4. Register the recipe. 0 14 1 * * = 14:00 UTC on the 1st = 8am CST / 9am CDT.
-- Peter said "8am CST" literally; matches Monthly Close Checklist Generator anchor.
INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
  composio_action, internal_handler, is_active
)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  'Leslie Monthly Goals Check-in',
  'On the 1st of each month at 8am CST, posts in Paper Newt Management group asking Marie whether Leslie hit her goals in the prior month. Reply captured to leslie_monthly_checkin.',
  'cron',
  '0 14 1 * *',
  'INTERNAL',
  'leslie_monthly_goals_send',
  true
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND recipe_name = 'Leslie Monthly Goals Check-in'
);
