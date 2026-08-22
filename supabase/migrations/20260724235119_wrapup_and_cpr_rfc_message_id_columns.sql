-- Add RFC-2822 Message-ID columns so replies can be routed back to their
-- original week via In-Reply-To header (which carries the RFC id, NOT the
-- Gmail internal id currently stored in *.gmail_message_id).
--
-- Both columns are nullable + backfilled lazily; existing rows stay valid.

ALTER TABLE public.wrapup_nag_log
  ADD COLUMN IF NOT EXISTS nag_message_id_rfc text;

ALTER TABLE public.weekly_cpr_reports
  ADD COLUMN IF NOT EXISTS cpr_recap_message_id_rfc text;

CREATE INDEX IF NOT EXISTS idx_wrapup_nag_log_nag_rfc
  ON public.wrapup_nag_log(nag_message_id_rfc)
  WHERE nag_message_id_rfc IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_weekly_cpr_reports_cpr_rfc
  ON public.weekly_cpr_reports(cpr_recap_message_id_rfc)
  WHERE cpr_recap_message_id_rfc IS NOT NULL;

COMMENT ON COLUMN public.wrapup_nag_log.nag_message_id_rfc IS
  'RFC-2822 Message-ID of the nag email we sent. Populated by wrapup_ingest parser after each send. Used to route teammate nag replies back to the correct week via their In-Reply-To header.';

COMMENT ON COLUMN public.weekly_cpr_reports.cpr_recap_message_id_rfc IS
  'RFC-2822 Message-ID of the CPR RECAP email that was sent. Used to route teammate CPR replies back to the correct week via their In-Reply-To header. gmail_message_id (Gmail internal id) does not match In-Reply-To format.';
