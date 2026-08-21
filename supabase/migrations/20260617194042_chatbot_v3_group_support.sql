-- Add chat-type tracking
ALTER TABLE public.chatbot_conversations
  ADD COLUMN IF NOT EXISTS chat_type text NOT NULL DEFAULT 'private',
  ADD COLUMN IF NOT EXISTS chat_title text;

-- Swap unique key from (agency, user) to (agency, chat) so groups can have one shared conversation
ALTER TABLE public.chatbot_conversations
  DROP CONSTRAINT IF EXISTS chatbot_conversations_agency_id_telegram_user_id_key;

ALTER TABLE public.chatbot_conversations
  ADD CONSTRAINT chatbot_conversations_agency_chat_unique
  UNIQUE (agency_id, telegram_chat_id);

-- Per-message speaker tracking (for group context — who said what)
ALTER TABLE public.chatbot_messages
  ADD COLUMN IF NOT EXISTS speaker_telegram_user_id bigint,
  ADD COLUMN IF NOT EXISTS speaker_first_name text,
  ADD COLUMN IF NOT EXISTS speaker_team_id uuid;

CREATE INDEX IF NOT EXISTS chatbot_messages_speaker_idx
  ON public.chatbot_messages (speaker_telegram_user_id, created_at);

COMMENT ON COLUMN public.chatbot_conversations.chat_type IS 'Telegram chat type: private | group | supergroup | channel. Drives system prompt branching.';
COMMENT ON COLUMN public.chatbot_conversations.chat_title IS 'Group/supergroup title (null for DMs).';
COMMENT ON COLUMN public.chatbot_messages.speaker_telegram_user_id IS 'For role=user messages: the Telegram user_id of the speaker. NULL for assistant/system_note.';
COMMENT ON COLUMN public.chatbot_messages.speaker_first_name IS 'Denormalized first name of the speaker for history readability.';
