-- Reference write-ups arrive as body-only emails ("Reference N - <name>").
-- Until 2026-08-19 nothing ingested them: the document-processor's default door
-- is gated on has:attachment. This table is the landing spot for the new
-- "references" mode.
CREATE TABLE IF NOT EXISTS hiring_candidate_references (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  candidate_id uuid REFERENCES hiring_candidates(id),
  candidate_name_from_subject text NOT NULL,
  reference_number int,
  gmail_thread_id text NOT NULL,
  gmail_message_id text NOT NULL,
  sender text,
  received_at timestamptz,
  subject text NOT NULL,
  body text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_hcr_gmail_message
  ON hiring_candidate_references(gmail_message_id);
CREATE INDEX IF NOT EXISTS idx_hcr_candidate
  ON hiring_candidate_references(candidate_id);

ALTER TABLE hiring_candidate_references ENABLE ROW LEVEL SECURITY;

-- Mirrors hiring_candidates: admin-only in the app; the edge function writes
-- through the service role, which bypasses these.
DROP POLICY IF EXISTS hcr_admin_read ON hiring_candidate_references;
CREATE POLICY hcr_admin_read ON hiring_candidate_references
  FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
DROP POLICY IF EXISTS hcr_admin_update ON hiring_candidate_references;
CREATE POLICY hcr_admin_update ON hiring_candidate_references
  FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
DROP POLICY IF EXISTS hcr_admin_delete ON hiring_candidate_references;
CREATE POLICY hcr_admin_delete ON hiring_candidate_references
  FOR DELETE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
