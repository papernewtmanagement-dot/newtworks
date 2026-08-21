-- Persistent log of every message that flows through the @pjsagencybot
-- group-chat webhook. Captures structured checkin replies AND general team
-- chatter that previously was dropped on the floor. Idempotent on
-- (agency_id, chat_id, message_id) so Telegram retries / message edits
-- don't double-insert.

CREATE TABLE IF NOT EXISTS public.telegram_group_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,

  -- Telegram identifiers
  telegram_chat_id bigint NOT NULL,
  telegram_message_id bigint NOT NULL,
  telegram_user_id bigint,
  telegram_username text,
  telegram_first_name text,
  telegram_last_name text,

  -- Roster mapping (NULL if sender isn't mapped to public.team)
  team_id uuid REFERENCES public.team(id) ON DELETE SET NULL,

  -- Content
  text text,
  is_bot boolean NOT NULL DEFAULT false,
  is_edited boolean NOT NULL DEFAULT false,
  reply_to_message_id bigint,

  -- How the webhook classified this message after parsing.
  -- One of: 'text', 'command', 'checkin_work', 'checkin_health',
  -- 'mention_or_reply', 'edit', 'ignored_excluded', 'ignored_other'.
  message_type text NOT NULL DEFAULT 'text',

  -- Forensic fallback — store the full Telegram update so nothing is lost
  -- if a future consumer needs a field we didn't extract.
  raw_update jsonb,

  -- Timestamps
  sent_at timestamptz NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT telegram_group_messages_unique
    UNIQUE (agency_id, telegram_chat_id, telegram_message_id)
);

CREATE INDEX IF NOT EXISTS idx_tgm_agency_chat_sent_at
  ON public.telegram_group_messages (agency_id, telegram_chat_id, sent_at DESC);

CREATE INDEX IF NOT EXISTS idx_tgm_team_sent_at
  ON public.telegram_group_messages (team_id, sent_at DESC)
  WHERE team_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_tgm_message_type
  ON public.telegram_group_messages (agency_id, message_type, sent_at DESC);

-- RLS: tight from the start. Service role bypasses RLS (edge function works).
-- Authenticated users (BCC app) get read-only SELECT.
-- Anon role gets NOTHING — this table can carry off-the-cuff team chatter
-- and has no business being world-readable.
ALTER TABLE public.telegram_group_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS telegram_group_messages_authenticated_read
  ON public.telegram_group_messages;

CREATE POLICY telegram_group_messages_authenticated_read
  ON public.telegram_group_messages
  FOR SELECT
  TO authenticated
  USING (true);

COMMENT ON TABLE public.telegram_group_messages IS
  'Persistent log of every Telegram group-chat message processed by the @pjsagencybot webhook (chat_id from settings.telegram_team_group_chat_id). Populated by the telegram edge function on each inbound update. Idempotent via the unique constraint on (agency_id, chat_id, message_id). Use for cross-run context in checkin compilers and the Friday wrapup. Service role writes; authenticated reads; anon blocked.';
