ALTER TABLE public.agency_snapshot
  ADD COLUMN IF NOT EXISTS source_message_id text;

COMMENT ON COLUMN public.agency_snapshot.source_message_id IS
  'Gmail messageId of the SF CRM Analytics email this row was parsed from. Used by automation-runner internal_parser=sf_crm_analytics_email for email-level dedup.';

CREATE INDEX IF NOT EXISTS agency_snapshot_source_message_id_idx
  ON public.agency_snapshot (source_message_id)
  WHERE source_message_id IS NOT NULL;
