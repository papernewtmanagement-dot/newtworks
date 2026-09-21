-- Reference calling (items 3 and 4) — schema only.
--
-- Item 3 needs to know when the caller was last nagged, so the Telegram nudge
-- can fire once a day instead of once an hour. Item 4 needs to know which
-- round of attempts a contact is on: round 1 is the first three attempts,
-- round 2 is the three that open three days after the candidate is asked for
-- help. Everything else item 4 needs already exists on hiring_candidates.
--
-- contact_id ties a phone write-up back to the person who was called. Without
-- it the only link is reference_number matching slot_number by convention,
-- which breaks the moment a slot is re-entered.

ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS reference_caller_nudged_at timestamptz;

ALTER TABLE public.hiring_reference_contacts
  ADD COLUMN IF NOT EXISTS round smallint NOT NULL DEFAULT 1;

ALTER TABLE public.hiring_candidate_references
  ADD COLUMN IF NOT EXISTS contact_id uuid
    REFERENCES public.hiring_reference_contacts(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS hiring_candidate_references_contact_idx
  ON public.hiring_candidate_references (contact_id)
  WHERE contact_id IS NOT NULL;

COMMENT ON COLUMN public.hiring_reference_contacts.round IS
  'Which round of calling this contact is on. 1 = the first three attempts. 2 = the three that open three days after the candidate is emailed for help. Attempts are cumulative, so a round is exhausted at attempt_count >= 3 * round.';

COMMENT ON COLUMN public.hiring_candidate_references.contact_id IS
  'The reference contact this write-up came from, when it came from a phone call. Email write-ups predate the contacts table and leave this null.';
