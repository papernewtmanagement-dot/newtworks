-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-10 15:59:09 UTC (ledger name: phase3_referrals_and_gbp_reviews) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260710155909.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Phase 3: record-level tables for referrals + Google Business Profile reviews.
-- Sit ALONGSIDE marketing_points (weekly aggregate stays canonical for the 7/11 pool rollout).
-- Later work can auto-derive marketing_points from these tables via view/trigger.

-- ══════════════════════════════════════════════════════════════
-- referrals — one row per referred household
-- ══════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.referrals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  referred_by_name text NOT NULL,
  referred_household_name text NOT NULL,
  referred_at date NOT NULL DEFAULT CURRENT_DATE,
  assigned_to uuid REFERENCES public.team(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'received',
  quoted_at date,
  sold_at date,
  bind_premium numeric,
  lob text,
  referral_source text,
  spiff_paid_at date,
  spiff_amount numeric,
  notes text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  created_by uuid,
  CONSTRAINT referrals_status_chk CHECK (status IN ('received','contacted','quoted','sold','dead')),
  CONSTRAINT referrals_lob_chk CHECK (lob IS NULL OR lob IN ('Auto','Fire','Life','Multi')),
  CONSTRAINT referrals_source_chk CHECK (referral_source IS NULL OR referral_source IN ('customer','employee','partner','family','other'))
);
CREATE INDEX IF NOT EXISTS idx_referrals_agency_status ON public.referrals(agency_id, status);
CREATE INDEX IF NOT EXISTS idx_referrals_agency_referred_at ON public.referrals(agency_id, referred_at DESC);
CREATE INDEX IF NOT EXISTS idx_referrals_assigned ON public.referrals(assigned_to);

ALTER TABLE public.referrals ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "anon_all_referrals" ON public.referrals;
DROP POLICY IF EXISTS "authenticated_all_referrals" ON public.referrals;
CREATE POLICY "anon_all_referrals" ON public.referrals FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "authenticated_all_referrals" ON public.referrals FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- updated_at trigger
CREATE OR REPLACE FUNCTION public.touch_referrals_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END; $$;
DROP TRIGGER IF EXISTS trg_referrals_updated_at ON public.referrals;
CREATE TRIGGER trg_referrals_updated_at BEFORE UPDATE ON public.referrals
  FOR EACH ROW EXECUTE FUNCTION public.touch_referrals_updated_at();

-- ══════════════════════════════════════════════════════════════
-- gbp_reviews — one row per Google Business Profile review
-- ══════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.gbp_reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  google_review_id text UNIQUE,
  reviewer_name text NOT NULL,
  rating int NOT NULL,
  review_text text,
  review_date date NOT NULL DEFAULT CURRENT_DATE,
  responded_at timestamptz,
  responded_by uuid REFERENCES public.team(id) ON DELETE SET NULL,
  response_text text,
  attributed_to uuid REFERENCES public.team(id) ON DELETE SET NULL,
  icp_flag boolean DEFAULT false,
  notes text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  created_by uuid,
  CONSTRAINT gbp_reviews_rating_chk CHECK (rating BETWEEN 1 AND 5)
);
CREATE INDEX IF NOT EXISTS idx_gbp_reviews_agency_date ON public.gbp_reviews(agency_id, review_date DESC);
CREATE INDEX IF NOT EXISTS idx_gbp_reviews_needs_response ON public.gbp_reviews(agency_id) WHERE responded_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_gbp_reviews_attributed ON public.gbp_reviews(attributed_to);

ALTER TABLE public.gbp_reviews ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "anon_all_gbp_reviews" ON public.gbp_reviews;
DROP POLICY IF EXISTS "authenticated_all_gbp_reviews" ON public.gbp_reviews;
CREATE POLICY "anon_all_gbp_reviews" ON public.gbp_reviews FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "authenticated_all_gbp_reviews" ON public.gbp_reviews FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- updated_at trigger
CREATE OR REPLACE FUNCTION public.touch_gbp_reviews_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END; $$;
DROP TRIGGER IF EXISTS trg_gbp_reviews_updated_at ON public.gbp_reviews;
CREATE TRIGGER trg_gbp_reviews_updated_at BEFORE UPDATE ON public.gbp_reviews
  FOR EACH ROW EXECUTE FUNCTION public.touch_gbp_reviews_updated_at();

COMMENT ON TABLE public.referrals IS 'Individual referral records. Feeds Referrals & Reviews tab. Weekly aggregate remains in marketing_points until Phase 3.5 auto-derive lands.';
COMMENT ON TABLE public.gbp_reviews IS 'Individual Google Business Profile reviews. Feeds Referrals & Reviews tab + ICP research pool.';
