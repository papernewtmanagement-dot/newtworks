-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-03 23:19:55 UTC (ledger name: fit_scorecards_schema) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260703231955.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Migration: fit_scorecards
-- Team-facing FIT Scorecard entries per handbook 04 Win the Week + playbook 04 Daily Checklist.
-- Team-visible module (Peter authorized 2026-07-03) — open training loop.
-- Cadence by tenure (denormalized at entry time):
--   weeks_1_8     Scorecard & record every conversation
--   weeks_9_13    Scorecard & record every quote/review
--   weeks_14_plus Scorecard at EOD + record one quote/review
-- Post-training returns to weeks_14_plus cadence, scaled by current sales-points rating.
-- Rating: 1 = spoke words / 2 = average / 3 = great; NULL = N/A for that step.
-- 10 dimensions in FIT order: Demeanor, FROGS, Intro, Determine Eligibility, Setup GNC,
-- Uncover the Gap, Bridge the Gap, Customize & Close, Set FU, Review & Referral.

CREATE TABLE IF NOT EXISTS public.fit_scorecards (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id UUID NOT NULL,
  team_member_id UUID NOT NULL REFERENCES public.team(id) ON DELETE RESTRICT,
  created_by_user_id UUID,

  scorecard_date DATE NOT NULL DEFAULT CURRENT_DATE,
  entry_type TEXT NOT NULL CHECK (entry_type IN ('conversation','quote_review','end_of_day')),
  tenure_tier_at_entry TEXT NOT NULL CHECK (tenure_tier_at_entry IN ('weeks_1_8','weeks_9_13','weeks_14_plus')),

  customer_first_name TEXT,
  opportunity_ref TEXT,
  recording_turned_in BOOLEAN NOT NULL DEFAULT false,
  recording_url TEXT,

  -- 10 FIT dimensions, 1-3 per handbook grading, NULL = not applicable this entry
  demeanor_score        INT CHECK (demeanor_score        BETWEEN 1 AND 3),
  frogs_score           INT CHECK (frogs_score           BETWEEN 1 AND 3),
  intro_score           INT CHECK (intro_score           BETWEEN 1 AND 3),
  eligibility_score     INT CHECK (eligibility_score     BETWEEN 1 AND 3),
  setup_gnc_score       INT CHECK (setup_gnc_score       BETWEEN 1 AND 3),
  uncover_gap_score     INT CHECK (uncover_gap_score     BETWEEN 1 AND 3),
  bridge_gap_score      INT CHECK (bridge_gap_score      BETWEEN 1 AND 3),
  customize_close_score INT CHECK (customize_close_score BETWEEN 1 AND 3),
  set_followup_score    INT CHECK (set_followup_score    BETWEEN 1 AND 3),
  review_referral_score INT CHECK (review_referral_score BETWEEN 1 AND 3),

  notes TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Generated average column (STORED). Average of non-null scores across the 10 dimensions.
ALTER TABLE public.fit_scorecards
  ADD COLUMN IF NOT EXISTS average_score NUMERIC(4,2) GENERATED ALWAYS AS (
    CASE
      WHEN (
        (demeanor_score IS NOT NULL)::int +
        (frogs_score IS NOT NULL)::int +
        (intro_score IS NOT NULL)::int +
        (eligibility_score IS NOT NULL)::int +
        (setup_gnc_score IS NOT NULL)::int +
        (uncover_gap_score IS NOT NULL)::int +
        (bridge_gap_score IS NOT NULL)::int +
        (customize_close_score IS NOT NULL)::int +
        (set_followup_score IS NOT NULL)::int +
        (review_referral_score IS NOT NULL)::int
      ) > 0
      THEN (
        COALESCE(demeanor_score,0) + COALESCE(frogs_score,0) + COALESCE(intro_score,0) +
        COALESCE(eligibility_score,0) + COALESCE(setup_gnc_score,0) + COALESCE(uncover_gap_score,0) +
        COALESCE(bridge_gap_score,0) + COALESCE(customize_close_score,0) +
        COALESCE(set_followup_score,0) + COALESCE(review_referral_score,0)
      )::numeric / (
        (demeanor_score IS NOT NULL)::int + (frogs_score IS NOT NULL)::int +
        (intro_score IS NOT NULL)::int + (eligibility_score IS NOT NULL)::int +
        (setup_gnc_score IS NOT NULL)::int + (uncover_gap_score IS NOT NULL)::int +
        (bridge_gap_score IS NOT NULL)::int + (customize_close_score IS NOT NULL)::int +
        (set_followup_score IS NOT NULL)::int + (review_referral_score IS NOT NULL)::int
      )
      ELSE NULL
    END
  ) STORED;

CREATE INDEX IF NOT EXISTS idx_fit_scorecards_agency_member_date
  ON public.fit_scorecards(agency_id, team_member_id, scorecard_date DESC);

CREATE INDEX IF NOT EXISTS idx_fit_scorecards_agency_date
  ON public.fit_scorecards(agency_id, scorecard_date DESC);

-- updated_at trigger
CREATE OR REPLACE FUNCTION public.fit_scorecards_touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_fit_scorecards_touch_updated_at ON public.fit_scorecards;
CREATE TRIGGER trg_fit_scorecards_touch_updated_at
  BEFORE UPDATE ON public.fit_scorecards
  FOR EACH ROW EXECUTE FUNCTION public.fit_scorecards_touch_updated_at();

-- Helper: tenure tier for a team member as of a given date (Sunday-anchored weeks-since-hire).
CREATE OR REPLACE FUNCTION public.fit_scorecard_tenure_tier(p_team_id UUID, p_as_of DATE DEFAULT CURRENT_DATE)
RETURNS TEXT LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN t.hire_date IS NULL AND t.start_date IS NULL THEN 'weeks_14_plus'
    WHEN (p_as_of - COALESCE(t.hire_date, t.start_date))::int / 7 < 9  THEN 'weeks_1_8'
    WHEN (p_as_of - COALESCE(t.hire_date, t.start_date))::int / 7 < 14 THEN 'weeks_9_13'
    ELSE 'weeks_14_plus'
  END
  FROM public.team t
  WHERE t.id = p_team_id;
$$;

GRANT EXECUTE ON FUNCTION public.fit_scorecard_tenure_tier(UUID, DATE) TO authenticated, anon, service_role;

-- RLS — match app's standard pattern (agency isolation + authenticated write).
-- Row-level access enforced at the app layer via NAV_ITEMS role check (team-visible module).
ALTER TABLE public.fit_scorecards ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS fit_scorecards_agency_isolation ON public.fit_scorecards;
CREATE POLICY fit_scorecards_agency_isolation
  ON public.fit_scorecards
  FOR ALL
  TO authenticated, anon
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

GRANT SELECT ON public.fit_scorecards TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.fit_scorecards TO authenticated;
