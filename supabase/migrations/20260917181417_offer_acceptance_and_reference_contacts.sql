-- =========================================================================
-- Contingent offer acceptance + reference contacts
-- =========================================================================
-- The candidate accepts the contingent offer on a public page reached by a
-- one-time link. On that page they give their date of birth, address, Social
-- Security number and the three people we should call for references. That
-- replaces the line in the offer letter asking when we can phone them for
-- those details.
--
-- Three design points worth stating because a later reader will ask:
--
-- 1. Reference write-ups live in ONE table whatever channel they arrived by.
--    hiring_candidate_references already held the ones that came in by email.
--    A phone call now writes a row in the same table with source='call', so
--    reference_is_positive() stays the only test of a good reference and
--    onboarding_sync_reference_steps() needed no change at all.
--
-- 2. The Social Security number lives in team_form_secure, the same table the
--    login-gated payroll form uses, so there is one place to look and one
--    purge to run. That table used to hang off a form submission, which hangs
--    off a team row, and an accepted candidate has no team row yet. So the
--    table now takes either a submission or a candidate, exactly one of them.
--
-- 3. The acceptance link carries a Social Security number, so it is short
--    lived and single use: seven days from the moment the offer is sent, and
--    dead the second the candidate presses accept. Peter re-sending the offer
--    issues a fresh link.
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. Reference write-ups can arrive by phone, not just email
-- -------------------------------------------------------------------------
ALTER TABLE public.hiring_candidate_references
  ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'email';

ALTER TABLE public.hiring_candidate_references
  ALTER COLUMN gmail_thread_id  DROP NOT NULL,
  ALTER COLUMN gmail_message_id DROP NOT NULL,
  ALTER COLUMN subject          DROP NOT NULL,
  ALTER COLUMN body             DROP NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'hiring_candidate_references_source_chk') THEN
    ALTER TABLE public.hiring_candidate_references
      ADD CONSTRAINT hiring_candidate_references_source_chk
      CHECK (source IN ('email','call'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'hiring_candidate_references_email_ids_chk') THEN
    ALTER TABLE public.hiring_candidate_references
      ADD CONSTRAINT hiring_candidate_references_email_ids_chk
      CHECK (source <> 'email' OR (gmail_thread_id IS NOT NULL AND gmail_message_id IS NOT NULL));
  END IF;
END $$;

COMMENT ON COLUMN public.hiring_candidate_references.source IS
  'email = arrived as a written reply. call = someone rang the reference and wrote up the answers. Both are scored by reference_is_positive().';

-- -------------------------------------------------------------------------
-- 2. The three people we will call
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.hiring_reference_contacts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id       uuid NOT NULL,
  candidate_id    uuid NOT NULL REFERENCES public.hiring_candidates(id) ON DELETE CASCADE,
  slot_number     integer NOT NULL CHECK (slot_number BETWEEN 1 AND 5),

  contact_name    text NOT NULL,
  relationship    text,
  company         text,
  phone           text,
  email           text,
  submitted_at    timestamptz NOT NULL DEFAULT now(),

  attempt_count   integer NOT NULL DEFAULT 0,
  attempts        jsonb   NOT NULL DEFAULT '[]'::jsonb,
  last_attempt_at timestamptz,
  reached_at      timestamptz,
  call_notes      text,
  outcome         text NOT NULL DEFAULT 'pending'
                   CHECK (outcome IN ('pending','reached','unreachable','declined_to_speak')),

  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS hiring_reference_contacts_slot_uq
  ON public.hiring_reference_contacts (candidate_id, slot_number);
CREATE INDEX IF NOT EXISTS hiring_reference_contacts_candidate_idx
  ON public.hiring_reference_contacts (candidate_id);

COMMENT ON TABLE public.hiring_reference_contacts IS
  'Who to ring for a reference, and how the ringing went. The candidate types these in when accepting the contingent offer. What the reference actually said is written up in hiring_candidate_references with source=call, so there is only ever one scorer.';
COMMENT ON COLUMN public.hiring_reference_contacts.attempts IS
  'One entry per try: {"at": timestamp, "by": team id or name, "answered": bool, "note": text}.';

ALTER TABLE public.hiring_reference_contacts ENABLE ROW LEVEL SECURITY;

-- -------------------------------------------------------------------------
-- 3. Acceptance link, the details the candidate gives us, and who calls
-- -------------------------------------------------------------------------
ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS offer_accept_token            text,
  ADD COLUMN IF NOT EXISTS offer_accept_expires_at       timestamptz,
  ADD COLUMN IF NOT EXISTS offer_accepted_at             timestamptz,
  ADD COLUMN IF NOT EXISTS offer_accept_signed_name      text,
  ADD COLUMN IF NOT EXISTS date_of_birth                 date,
  ADD COLUMN IF NOT EXISTS address_line1                 text,
  ADD COLUMN IF NOT EXISTS address_line2                 text,
  ADD COLUMN IF NOT EXISTS city                          text,
  ADD COLUMN IF NOT EXISTS state                         text,
  ADD COLUMN IF NOT EXISTS zip_code                      text,
  ADD COLUMN IF NOT EXISTS reference_caller_kind         text NOT NULL DEFAULT 'retention',
  ADD COLUMN IF NOT EXISTS reference_caller_team_id      uuid REFERENCES public.team(id),
  ADD COLUMN IF NOT EXISTS reference_caller_name         text,
  ADD COLUMN IF NOT EXISTS reference_caller_email        text,
  ADD COLUMN IF NOT EXISTS reference_caller_phone        text,
  ADD COLUMN IF NOT EXISTS reference_caller_assigned_at  timestamptz,
  ADD COLUMN IF NOT EXISTS reference_caller_notified_at  timestamptz,
  ADD COLUMN IF NOT EXISTS reference_round_started_at    timestamptz,
  ADD COLUMN IF NOT EXISTS reference_help_email_sent_at  timestamptz,
  ADD COLUMN IF NOT EXISTS reference_round2_opens_at     timestamptz,
  ADD COLUMN IF NOT EXISTS reference_final_email_sent_at timestamptz,
  ADD COLUMN IF NOT EXISTS reference_paused_at           timestamptz,
  ADD COLUMN IF NOT EXISTS reference_paused_reason       text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'hiring_candidates_reference_caller_kind_chk') THEN
    ALTER TABLE public.hiring_candidates
      ADD CONSTRAINT hiring_candidates_reference_caller_kind_chk
      CHECK (reference_caller_kind IN ('team','outside','retention'));
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS hiring_candidates_offer_accept_token_uq
  ON public.hiring_candidates (offer_accept_token)
  WHERE offer_accept_token IS NOT NULL;

COMMENT ON COLUMN public.hiring_candidates.offer_accept_token IS
  'The secret in the acceptance link. Cleared the moment the candidate accepts, so the link only ever works once.';
COMMENT ON COLUMN public.hiring_candidates.reference_caller_kind IS
  'retention = whoever is on the retention team. team = one named teammate. outside = someone who does not work here, held in reference_caller_name/email/phone.';

-- -------------------------------------------------------------------------
-- 4. The Social Security number goes where the other one goes
-- -------------------------------------------------------------------------
ALTER TABLE public.team_form_secure
  ADD COLUMN IF NOT EXISTS candidate_id uuid REFERENCES public.hiring_candidates(id) ON DELETE CASCADE;

ALTER TABLE public.team_form_secure
  ALTER COLUMN submission_id DROP NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'team_form_secure_one_anchor_chk') THEN
    ALTER TABLE public.team_form_secure
      ADD CONSTRAINT team_form_secure_one_anchor_chk
      CHECK ((submission_id IS NOT NULL) <> (candidate_id IS NOT NULL));
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS team_form_secure_candidate_uq
  ON public.team_form_secure (candidate_id)
  WHERE candidate_id IS NOT NULL;

COMMENT ON COLUMN public.team_form_secure.candidate_id IS
  'Set instead of submission_id when the number came from a candidate accepting a contingent offer, before there is a team row to hang a form submission on.';
