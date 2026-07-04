-- Migration: fit_scorecards
-- Simple Conversation FIT Scorecards — team self-assessment table + tenure helper.
-- Applied to Supabase via apply_migration on 2026-07-03. This file mirrors the
-- exact schema state for git parity with supabase/migrations/ convention.
-- Team-visible module (Peter authorized 2026-07-03) — open training loop.

CREATE TABLE IF NOT EXISTS public.fit_scorecards (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id              UUID NOT NULL,
  team_member_id         UUID NOT NULL REFERENCES public.team(id) ON DELETE RESTRICT,
  created_by_user_id     UUID,
  scorecard_date         DATE NOT NULL DEFAULT CURRENT_DATE,
  entry_type             TEXT NOT NULL CHECK (entry_type IN ('conversation','quote_review','end_of_day')),
  tenure_tier_at_entry   TEXT NOT NULL CHECK (tenure_tier_at_entry IN ('weeks_1_8','weeks_9_13','weeks_14_plus')),
  customer_first_name    TEXT,
  opportunity_ref        TEXT,
  recording_turned_in    BOOLEAN NOT NULL DEFAULT false,
  recording_url          TEXT,
  demeanor_score         INTEGER CHECK (demeanor_score        BETWEEN 1 AND 3),
  frogs_score            INTEGER CHECK (frogs_score           BETWEEN 1 AND 3),
  intro_score            INTEGER CHECK (intro_score           BETWEEN 1 AND 3),
  eligibility_score      INTEGER CHECK (eligibility_score     BETWEEN 1 AND 3),
  setup_gnc_score        INTEGER CHECK (setup_gnc_score       BETWEEN 1 AND 3),
  uncover_gap_score      INTEGER CHECK (uncover_gap_score     BETWEEN 1 AND 3),
  bridge_gap_score       INTEGER CHECK (bridge_gap_score      BETWEEN 1 AND 3),
  customize_close_score  INTEGER CHECK (customize_close_score BETWEEN 1 AND 3),
  set_followup_score     INTEGER CHECK (set_followup_score    BETWEEN 1 AND 3),
  review_referral_score  INTEGER CHECK (review_referral_score BETWEEN 1 AND 3),
  notes                  TEXT,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  average_score          NUMERIC GENERATED ALWAYS AS (
    (
      COALESCE(demeanor_score,0)        + COALESCE(frogs_score,0)          +
      COALESCE(intro_score,0)           + COALESCE(eligibility_score,0)    +
      COALESCE(setup_gnc_score,0)       + COALESCE(uncover_gap_score,0)    +
      COALESCE(bridge_gap_score,0)      + COALESCE(customize_close_score,0)+
      COALESCE(set_followup_score,0)    + COALESCE(review_referral_score,0)
    )::numeric
    / NULLIF(
      (demeanor_score        IS NOT NULL)::int + (frogs_score           IS NOT NULL)::int +
      (intro_score           IS NOT NULL)::int + (eligibility_score     IS NOT NULL)::int +
      (setup_gnc_score       IS NOT NULL)::int + (uncover_gap_score     IS NOT NULL)::int +
      (bridge_gap_score      IS NOT NULL)::int + (customize_close_score IS NOT NULL)::int +
      (set_followup_score    IS NOT NULL)::int + (review_referral_score IS NOT NULL)::int,
      0
    )
  ) STORED
);

CREATE INDEX IF NOT EXISTS idx_fit_scorecards_agency_member_date
  ON public.fit_scorecards (agency_id, team_member_id, scorecard_date DESC);

CREATE INDEX IF NOT EXISTS idx_fit_scorecards_agency_date
  ON public.fit_scorecards (agency_id, scorecard_date DESC);

ALTER TABLE public.fit_scorecards ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS fit_scorecards_agency_isolation ON public.fit_scorecards;
CREATE POLICY fit_scorecards_agency_isolation
  ON public.fit_scorecards
  FOR ALL
  TO anon, authenticated
  USING      (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- Tenure tier helper: 'weeks_1_8' | 'weeks_9_13' | 'weeks_14_plus' from hire/start date.
CREATE OR REPLACE FUNCTION public.fit_scorecard_tenure_tier(
  p_team_id UUID,
  p_as_of   DATE DEFAULT CURRENT_DATE
) RETURNS TEXT
LANGUAGE sql STABLE
AS $function$
  SELECT CASE
    WHEN t.hire_date IS NULL AND t.start_date IS NULL THEN 'weeks_14_plus'
    WHEN (p_as_of - COALESCE(t.hire_date, t.start_date))::int / 7 < 9  THEN 'weeks_1_8'
    WHEN (p_as_of - COALESCE(t.hire_date, t.start_date))::int / 7 < 14 THEN 'weeks_9_13'
    ELSE 'weeks_14_plus'
  END
  FROM public.team t
  WHERE t.id = p_team_id;
$function$;
