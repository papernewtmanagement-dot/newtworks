-- A classifier "skip" in document-processor used to leave no trace at all:
-- processOneAttachment pushed a result with documentId "" and wrote no row
-- anywhere. A sender-gated classifier miss was therefore invisible to SQL,
-- which is why the 2026-09-16 sender-rule sweep had to be done by reading
-- code instead of querying data.
--
-- This table is that trace. One row per skipped attachment, keyed on
-- (agency_id, gmail_message_id, file_name) so the 7-day Gmail lookback
-- re-seeing the same attachment every hour bumps last_seen_at and seen_count
-- instead of piling up duplicates. Inner zip files carry no message id, so
-- gmail_message_id is NOT NULL DEFAULT '' — a NULL would defeat the unique
-- index (NULLs compare distinct) and reintroduce the duplicate pile.

CREATE TABLE IF NOT EXISTS public.document_classifier_skips (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id         uuid NOT NULL,
  gmail_message_id  text NOT NULL DEFAULT '',
  gmail_thread_id   text,
  file_name         text NOT NULL,
  mime_type         text,
  from_email        text,
  subject           text,
  received_at       timestamptz,
  upload_source     text,
  depth             smallint NOT NULL DEFAULT 0,
  first_seen_at     timestamptz NOT NULL DEFAULT now(),
  last_seen_at      timestamptz NOT NULL DEFAULT now(),
  seen_count        integer NOT NULL DEFAULT 1,
  reviewed_at       timestamptz,
  review_note       text
);

COMMENT ON TABLE public.document_classifier_skips IS
  'Queryable trace of every attachment document-processor classified as "skip". Upserted per (agency_id, gmail_message_id, file_name) by public.record_classifier_skip(). Sweep this instead of reading classifier.ts.';

CREATE UNIQUE INDEX IF NOT EXISTS document_classifier_skips_key
  ON public.document_classifier_skips (agency_id, gmail_message_id, file_name);

CREATE INDEX IF NOT EXISTS document_classifier_skips_last_seen
  ON public.document_classifier_skips (agency_id, last_seen_at DESC);

ALTER TABLE public.document_classifier_skips ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS document_classifier_skips_admin_read ON public.document_classifier_skips;
CREATE POLICY document_classifier_skips_admin_read
  ON public.document_classifier_skips
  FOR SELECT TO authenticated
  USING (is_agency_admin());

-- Writer. One function, one job: every caller goes through this so the upsert
-- key and the seen_count arithmetic live in exactly one place.
CREATE OR REPLACE FUNCTION public.record_classifier_skip(
  p_agency_id        uuid,
  p_file_name        text,
  p_gmail_message_id text DEFAULT NULL,
  p_gmail_thread_id  text DEFAULT NULL,
  p_mime_type        text DEFAULT NULL,
  p_from_email       text DEFAULT NULL,
  p_subject          text DEFAULT NULL,
  p_received_at      timestamptz DEFAULT NULL,
  p_upload_source    text DEFAULT NULL,
  p_depth            smallint DEFAULT 0
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_id uuid;
BEGIN
  IF p_agency_id IS NULL OR COALESCE(btrim(p_file_name), '') = '' THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.document_classifier_skips AS s (
    agency_id, gmail_message_id, gmail_thread_id, file_name, mime_type,
    from_email, subject, received_at, upload_source, depth
  ) VALUES (
    p_agency_id, COALESCE(p_gmail_message_id, ''), p_gmail_thread_id,
    p_file_name, p_mime_type, p_from_email, p_subject, p_received_at,
    p_upload_source, COALESCE(p_depth, 0)
  )
  ON CONFLICT (agency_id, gmail_message_id, file_name) DO UPDATE
    SET last_seen_at     = now(),
        seen_count       = s.seen_count + 1,
        gmail_thread_id  = COALESCE(EXCLUDED.gmail_thread_id,  s.gmail_thread_id),
        mime_type        = COALESCE(EXCLUDED.mime_type,        s.mime_type),
        from_email       = COALESCE(EXCLUDED.from_email,       s.from_email),
        subject          = COALESCE(EXCLUDED.subject,          s.subject),
        received_at      = COALESCE(EXCLUDED.received_at,      s.received_at),
        upload_source    = COALESCE(EXCLUDED.upload_source,    s.upload_source)
  RETURNING s.id INTO v_id;

  RETURN v_id;
END;
$fn$;

REVOKE ALL ON FUNCTION public.record_classifier_skip(
  uuid, text, text, text, text, text, text, timestamptz, text, smallint
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_classifier_skip(
  uuid, text, text, text, text, text, text, timestamptz, text, smallint
) TO service_role;
