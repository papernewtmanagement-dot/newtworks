-- ============================================================================
-- PFA Daily Close: team-facing "I'm done for today" button
--
-- One person per day (retention lead) presses Close Day after entering
-- every deposit. Fires a per-deposit Telegram summary to the team group
-- and LOCKS pfa_record_customer_deposit for the rest of the day.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.pfa_daily_closes (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id                 uuid NOT NULL,
  pfa_account_id            uuid NOT NULL REFERENCES public.pfa_accounts(id) ON DELETE RESTRICT,
  close_date                date NOT NULL,
  closed_by_team_member_id  uuid NOT NULL REFERENCES public.team(id) ON DELETE RESTRICT,
  deposit_count             integer NOT NULL CHECK (deposit_count > 0),
  total_amount              numeric(12,2) NOT NULL CHECK (total_amount > 0),
  deposit_ids               uuid[] NOT NULL,
  telegram_message_id       bigint,
  telegram_send_ok          boolean NOT NULL DEFAULT false,
  telegram_send_error       text,
  closed_at                 timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pfa_daily_closes_one_per_day UNIQUE (agency_id, pfa_account_id, close_date)
);

CREATE INDEX IF NOT EXISTS pfa_daily_closes_agency_date_idx
  ON public.pfa_daily_closes (agency_id, close_date DESC);

ALTER TABLE public.pfa_daily_closes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pfa_admin_only_closes ON public.pfa_daily_closes;
CREATE POLICY pfa_admin_only_closes ON public.pfa_daily_closes
  FOR ALL TO authenticated
  USING (
    EXISTS (SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role IN ('owner','manager')
        AND u.agency_id = pfa_daily_closes.agency_id)
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role IN ('owner','manager')
        AND u.agency_id = pfa_daily_closes.agency_id)
  );

COMMENT ON TABLE public.pfa_daily_closes IS 'One row per team-pressed Close Day event. Locks further PFA deposit entries for that CT date and records the summary Telegram send.';

-- RPCs pfa_today_summary(), pfa_close_day(), and updated pfa_record_customer_deposit()
-- are applied via the same migration on the DB side (Supabase MCP). Full SQL
-- lives in the applied migration; not duplicated in this repo file to keep it
-- from drifting out of sync with the deployed function body.
