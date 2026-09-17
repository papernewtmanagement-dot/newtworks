-- Referral detail belongs on the production log, not a separate table.
-- Two columns: who on the team sourced it, and which customer gave it.

ALTER TABLE public.quote_log
  ADD COLUMN IF NOT EXISTS referred_by_customer text;

ALTER TABLE public.sales_log
  ADD COLUMN IF NOT EXISTS referred_by_customer text;

ALTER TABLE public.sales_log
  ADD COLUMN IF NOT EXISTS sourced_by_team_member_id uuid REFERENCES public.team(id);

COMMENT ON COLUMN public.quote_log.referred_by_customer IS
  'Name of the customer who gave the referral. Fill only when marketing_source is a referral.';
COMMENT ON COLUMN public.sales_log.referred_by_customer IS
  'Name of the customer who gave the referral. Fill only when marketing_source is a referral.';
COMMENT ON COLUMN public.sales_log.sourced_by_team_member_id IS
  'Team member who sourced the referral. Mirrors quote_log.sourced_by_team_member_id, which already existed.';
