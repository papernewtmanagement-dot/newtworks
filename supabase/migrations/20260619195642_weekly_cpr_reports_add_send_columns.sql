-- Manual-send button infrastructure for CPR weekly recap email.
-- opener_text + looking_next_week_text: the two Claude-drafted sections of the
-- canonical layout (operational_rule dc5e694a). Peter authors them in the
-- WeeklyCPR module OR they get pre-populated from chat. Button is disabled
-- until both are populated.
-- sent_to_team_at: idempotency stamp. Button disabled once set; resend
-- requires explicit re-arm.

ALTER TABLE public.weekly_cpr_reports
  ADD COLUMN IF NOT EXISTS opener_text text,
  ADD COLUMN IF NOT EXISTS looking_next_week_text text,
  ADD COLUMN IF NOT EXISTS sent_to_team_at timestamptz;

COMMENT ON COLUMN public.weekly_cpr_reports.opener_text IS
  'Section 1 of the weekly CPR email per operational_rule dc5e694a. Claude-drafted from real data, Peter-finalized in WeeklyCPR module before send.';
COMMENT ON COLUMN public.weekly_cpr_reports.looking_next_week_text IS
  'Section 3 of the weekly CPR email per operational_rule dc5e694a. Claude-drafted from real data, Peter-finalized in WeeklyCPR module before send.';
COMMENT ON COLUMN public.weekly_cpr_reports.sent_to_team_at IS
  'Idempotency stamp set by send_weekly_cpr_recap() on successful Gmail dispatch. NULL means the recap has not been sent. Used to disable the Send button and prevent double-sends. Clearing this column re-arms the button.';
