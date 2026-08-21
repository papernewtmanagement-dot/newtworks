-- chatbot_conversations: one logical row per (agency_id, telegram_user_id)
-- Stores per-user conversation metadata. Identity-bound; only mapped users have a row.
CREATE TABLE IF NOT EXISTS public.chatbot_conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  telegram_user_id bigint NOT NULL,
  telegram_chat_id bigint NOT NULL, -- For DMs this equals telegram_user_id
  telegram_username text,
  telegram_first_name text,
  telegram_last_name text,
  team_id uuid REFERENCES public.team(id) ON DELETE SET NULL,
  is_principal boolean NOT NULL DEFAULT false, -- True for Peter (Owner) — unlocks partner voice
  message_count integer NOT NULL DEFAULT 0,
  last_user_message_at timestamptz,
  last_assistant_message_at timestamptz,
  reset_at timestamptz, -- When user last sent /reset
  started_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, telegram_user_id)
);

-- chatbot_messages: turn-by-turn log
-- Roles: 'user', 'assistant', 'system_note' (internal events like /reset, errors)
CREATE TABLE IF NOT EXISTS public.chatbot_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES public.chatbot_conversations(id) ON DELETE CASCADE,
  agency_id uuid NOT NULL,
  role text NOT NULL CHECK (role IN ('user', 'assistant', 'system_note')),
  content text NOT NULL,
  telegram_message_id bigint, -- The Telegram message_id for user msgs; null for system_notes
  model text, -- e.g. 'claude-sonnet-4-6' for assistant msgs
  tokens_in integer,
  tokens_out integer,
  latency_ms integer,
  error_message text, -- Non-null if assistant turn errored
  is_after_reset boolean NOT NULL DEFAULT false, -- True if msg is part of post-/reset window (excluded from history if older convo reset)
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS chatbot_messages_convo_time_idx
  ON public.chatbot_messages (conversation_id, created_at DESC);

CREATE INDEX IF NOT EXISTS chatbot_conversations_telegram_user_idx
  ON public.chatbot_conversations (agency_id, telegram_user_id);

-- Comments for future readers
COMMENT ON TABLE public.chatbot_conversations IS 'Per-user conversation state for @paper_newt_bot Pocket CFO/COO. DM-only, identity-gated via team_telegram_map.';
COMMENT ON TABLE public.chatbot_messages IS 'Turn-by-turn message log for the Pocket CFO/COO Telegram chatbot. Includes both sides plus internal system_notes.';
COMMENT ON COLUMN public.chatbot_conversations.is_principal IS 'True for the agency principal (Peter Story). Unlocks partner voice + full BCC visibility in system prompt.';
COMMENT ON COLUMN public.chatbot_conversations.reset_at IS 'Timestamp of last /reset command. Messages with created_at < reset_at are excluded from history load.';

-- RLS — agency-isolated, mirroring the team_telegram_map pattern
ALTER TABLE public.chatbot_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chatbot_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS chatbot_conversations_agency_select ON public.chatbot_conversations;
CREATE POLICY chatbot_conversations_agency_select ON public.chatbot_conversations
  FOR SELECT USING (
    agency_id IN (SELECT agency_id FROM public.users WHERE id = auth.uid())
  );

DROP POLICY IF EXISTS chatbot_messages_agency_select ON public.chatbot_messages;
CREATE POLICY chatbot_messages_agency_select ON public.chatbot_messages
  FOR SELECT USING (
    agency_id IN (SELECT agency_id FROM public.users WHERE id = auth.uid())
  );

-- Edge function uses service role and bypasses RLS for inserts/updates.
-- Direct authenticated access from the BCC app is read-only via the policies above.
