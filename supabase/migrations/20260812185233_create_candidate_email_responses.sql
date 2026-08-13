-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-12 18:52:33 UTC (ledger name: create_candidate_email_responses) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260812185233.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
CREATE TABLE IF NOT EXISTS public.candidate_email_responses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  hiring_candidate_id uuid REFERENCES public.hiring_candidates(id) ON DELETE SET NULL,
  gmail_thread_id text,
  gmail_message_id text,
  from_email text,
  received_at timestamptz,
  subject text,
  body_excerpt text,
  response_type text NOT NULL CHECK (response_type IN (
    'interested_confirmation',
    'declining',
    'assessment_completed_notice',
    'interview_accepted',
    'bounced_undeliverable',
    'other'
  )),
  action_taken text,
  source_channel text,
  processed_at timestamptz DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_candidate_email_responses_message
  ON public.candidate_email_responses (agency_id, gmail_message_id)
  WHERE gmail_message_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_candidate_email_responses_candidate
  ON public.candidate_email_responses (hiring_candidate_id);

ALTER TABLE public.candidate_email_responses ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon_all_candidate_email_responses" ON public.candidate_email_responses
  FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY "authenticated_all_candidate_email_responses" ON public.candidate_email_responses
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

COMMENT ON TABLE public.candidate_email_responses IS 'One row per inbound candidate email reply matched to an existing hiring_candidates row (assessment confirmations, declines, Indeed relay messages, interview RSVPs, bounce notices). Logged for audit trail; decline/bounce side effects are also applied directly to hiring_candidates.';
