-- Adds a flag + timestamp to agency_snapshot tracking when the row was
-- populated by the SF CRM Analytics widget-subscription email parser.
--
-- Context: the Saturday agency_snapshot row is now pre-created earlier in the
-- week by the Telegram check-in flow (source='cpr_weekly_manual'). The
-- automation-runner CRM Analytics parser fires Friday 4:30 PM CT and merges
-- book columns into that pre-existing row using fill_nulls_only. Without a
-- dedicated flag, we can't tell at a glance whether the parser has already
-- landed the email data on this week's row.

ALTER TABLE public.agency_snapshot
  ADD COLUMN IF NOT EXISTS crm_analytics_ingested boolean NOT NULL DEFAULT false;

ALTER TABLE public.agency_snapshot
  ADD COLUMN IF NOT EXISTS crm_analytics_ingested_at timestamptz;

COMMENT ON COLUMN public.agency_snapshot.crm_analytics_ingested IS
  'True when this row was filled (in whole or part) from the parsed SF CRM Analytics widget email. Set post-write by automation-runner when internal_parser=sf_crm_analytics_email writes to this row.';

COMMENT ON COLUMN public.agency_snapshot.crm_analytics_ingested_at IS
  'Timestamp when the CRM Analytics parser last stamped this row. NULL means no email-driven ingest has occurred.';

-- Backfill: any historical row with a populated source_message_id was produced
-- by parsing an email. Stamp them true using updated_at as best proxy.
UPDATE public.agency_snapshot
   SET crm_analytics_ingested = true,
       crm_analytics_ingested_at = updated_at
 WHERE source_message_id IS NOT NULL
   AND source_message_id <> ''
   AND crm_analytics_ingested = false;
