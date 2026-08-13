-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-01 16:37:05 UTC (ledger name: team_renewals_and_notification_log) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260701163705.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
CREATE TABLE IF NOT EXISTS public.team_renewals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365',
  team_member_id uuid NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,
  renewal_type text NOT NULL,
  authority text,
  states text[] NOT NULL DEFAULT ARRAY[]::text[],
  due_date date NOT NULL,
  cycle_months int,
  initial_issue_date date,
  last_completed_at date,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active','complete_onetime','lapsed','not_applicable')),
  ce_required boolean NOT NULL DEFAULT true,
  hours_required int,
  ce_breakdown jsonb,
  notes text,
  source_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_team_renewals_member
  ON public.team_renewals(team_member_id, status);
CREATE INDEX IF NOT EXISTS idx_team_renewals_due_active
  ON public.team_renewals(due_date) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_team_renewals_agency
  ON public.team_renewals(agency_id);

ALTER TABLE public.team_renewals ENABLE ROW LEVEL SECURITY;

CREATE POLICY anon_read_team_renewals ON public.team_renewals
  FOR SELECT TO anon, authenticated
  USING (true);

CREATE POLICY authenticated_insert_team_renewals ON public.team_renewals
  FOR INSERT TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

CREATE POLICY authenticated_update_team_renewals ON public.team_renewals
  FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

CREATE POLICY authenticated_delete_team_renewals ON public.team_renewals
  FOR DELETE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

CREATE TABLE IF NOT EXISTS public.renewal_notification_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365',
  team_renewal_id uuid NOT NULL REFERENCES public.team_renewals(id) ON DELETE CASCADE,
  cadence_day int NOT NULL,
  channel text NOT NULL,
  recipient text NOT NULL,
  sent_at timestamptz NOT NULL DEFAULT now(),
  status text NOT NULL DEFAULT 'sent',
  error text
);

CREATE INDEX IF NOT EXISTS idx_renewal_notif_log_renewal
  ON public.renewal_notification_log(team_renewal_id, sent_at DESC);

-- Dedupe: same cadence_day + channel per renewal fires exactly once.
-- Past-due uses negative day-count (-1, -2, ...) so each day is a distinct row.
CREATE UNIQUE INDEX IF NOT EXISTS ux_renewal_notif_log_dedupe
  ON public.renewal_notification_log(team_renewal_id, cadence_day, channel);

ALTER TABLE public.renewal_notification_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY anon_read_renewal_notif_log ON public.renewal_notification_log
  FOR SELECT TO anon, authenticated USING (true);

CREATE POLICY authenticated_write_renewal_notif_log ON public.renewal_notification_log
  FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

CREATE OR REPLACE FUNCTION public.tg_team_renewals_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS team_renewals_updated_at ON public.team_renewals;
CREATE TRIGGER team_renewals_updated_at
  BEFORE UPDATE ON public.team_renewals
  FOR EACH ROW EXECUTE FUNCTION public.tg_team_renewals_updated_at();
