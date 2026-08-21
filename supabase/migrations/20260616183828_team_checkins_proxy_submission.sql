-- Allow proxy responses: someone (e.g. John) submitting on behalf of someone else (e.g. Cassandra)
ALTER TABLE public.team_checkins
  ADD COLUMN IF NOT EXISTS submitted_by_team_id uuid REFERENCES public.team(id),
  ADD COLUMN IF NOT EXISTS submitted_by_telegram_user_id bigint,
  ADD COLUMN IF NOT EXISTS is_proxy_submission boolean GENERATED ALWAYS AS
    (submitted_by_team_id IS DISTINCT FROM team_id) STORED,
  ADD COLUMN IF NOT EXISTS source_message_id bigint;

COMMENT ON COLUMN public.team_checkins.team_id IS
  'The team member the response is FOR (whose numbers these are).';
COMMENT ON COLUMN public.team_checkins.submitted_by_team_id IS
  'The team member who actually TYPED the message. Equal to team_id for own responses, different for proxy responses.';
COMMENT ON COLUMN public.team_checkins.is_proxy_submission IS
  'TRUE when someone else submitted these numbers on behalf of the team member. Useful for audit and for compile messages ("Cassandra (via John): 5/28").';
COMMENT ON COLUMN public.team_checkins.source_message_id IS
  'Telegram message_id of the source message. One Telegram message can produce multiple checkin rows (proxy for several people in one message).';

-- Drop the strict unique constraint and replace with ON CONFLICT pattern via index.
-- Same uniqueness (one response per person per checkin), but last-write-wins semantics.
-- Index already exists from prior migration; no schema change needed there.
