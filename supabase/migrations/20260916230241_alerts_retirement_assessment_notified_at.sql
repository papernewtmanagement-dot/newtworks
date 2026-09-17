-- Alerts module retirement, phase 3.
-- v1-assessment used an alerts row (alert_type 'v2_assessment_complete') as
-- its "already told Peter" gate before sending the completion Telegram DM.
-- The alerts table is being dropped, so the gate needs a real key of its own.
--
-- assessment_completed_at cannot serve: it is written in the same update that
-- immediately precedes the notify block, so it is always set by the time the
-- gate is read. This column is set only when the DM actually goes out.
ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS assessment_notified_at timestamptz;

COMMENT ON COLUMN public.hiring_candidates.assessment_notified_at IS
  'When the assessment-complete Telegram DM was sent to the owner. Set by the v1-assessment edge function; its presence is the "already notified" gate that stops a duplicate DM if finalize runs twice. Replaced the v2_assessment_complete alerts row on 2026-09-16 when the alerts table was retired.';

-- Backfill: every candidate who already has a completion alert on file has
-- already been notified, so carry that across before the table goes away.
UPDATE public.hiring_candidates hc
   SET assessment_notified_at = a.created_at
  FROM public.alerts a
 WHERE a.related_id = hc.id
   AND a.alert_type IN ('v1_assessment_complete', 'v2_assessment_complete')
   AND hc.assessment_notified_at IS NULL;
