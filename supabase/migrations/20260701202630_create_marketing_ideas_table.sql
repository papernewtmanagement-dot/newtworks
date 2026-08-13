-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-01 20:26:30 UTC (ledger name: create_marketing_ideas_table) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260701202630.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Marketing ideas backlog table with lifecycle (backlog → under_review → approved → promoted to tasks | killed)
CREATE TABLE IF NOT EXISTS public.marketing_ideas (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id             uuid NOT NULL,
  title                 text NOT NULL,
  description           text,
  category              text CHECK (category IN (
    'paid_leads','direct_mail','email_campaign','social_content',
    'community_event','referral_partner','networking','giveaway',
    'branding','digital_seo','content_video','retention_touch',
    'lead_magnet','other'
  )),
  status                text NOT NULL DEFAULT 'backlog' CHECK (status IN (
    'backlog','under_review','approved','scheduled','in_progress','completed','killed'
  )),
  source                text,
  source_page           text,
  target_audience       text,
  estimated_effort      text CHECK (estimated_effort IN ('low','medium','high') OR estimated_effort IS NULL),
  estimated_cost_low    numeric(10,2),
  estimated_cost_high   numeric(10,2),
  expected_return_notes text,
  required_resources    text,
  next_review_at        timestamptz,
  reviewed_at           timestamptz,
  decided_at            timestamptz,
  promoted_to_task_id   uuid REFERENCES public.tasks(id) ON DELETE SET NULL,
  related_task_refs     text[],
  notes                 text,
  tags                  text[],
  created_at            timestamptz NOT NULL DEFAULT NOW(),
  updated_at            timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_marketing_ideas_agency_status ON public.marketing_ideas(agency_id, status);
CREATE INDEX IF NOT EXISTS idx_marketing_ideas_category ON public.marketing_ideas(category);
CREATE INDEX IF NOT EXISTS idx_marketing_ideas_next_review ON public.marketing_ideas(next_review_at) WHERE next_review_at IS NOT NULL;

-- updated_at trigger
CREATE OR REPLACE FUNCTION public.tg_marketing_ideas_touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS marketing_ideas_touch_updated_at ON public.marketing_ideas;
CREATE TRIGGER marketing_ideas_touch_updated_at
  BEFORE UPDATE ON public.marketing_ideas
  FOR EACH ROW EXECUTE FUNCTION public.tg_marketing_ideas_touch_updated_at();

-- RLS mirroring tasks pattern (owner full; managers/team read-only for now — can widen later if team should suggest ideas)
ALTER TABLE public.marketing_ideas ENABLE ROW LEVEL SECURITY;

CREATE POLICY "marketing_ideas_owner_full" ON public.marketing_ideas
  FOR ALL
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM users u
      WHERE u.auth_user_id = auth.uid() AND u.role = 'owner'
    )
  )
  WITH CHECK (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM users u
      WHERE u.auth_user_id = auth.uid() AND u.role = 'owner'
    )
  );

CREATE POLICY "marketing_ideas_manager_read" ON public.marketing_ideas
  FOR SELECT
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM users u
      WHERE u.auth_user_id = auth.uid() AND u.role = 'manager'
    )
  );

COMMENT ON TABLE public.marketing_ideas IS 'Marketing ideas backlog with review lifecycle. Distinct from tasks — ideas incubate here until approved, then graduate to tasks with promoted_to_task_id back-link. Origin/rationale preserved even after graduation.';
