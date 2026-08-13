-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-11 06:28:00 UTC (ledger name: wtq_leaderboards_and_prize_cart_budget_2026_07_11) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260711062800.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- ═══════════════════════════════════════════════════════════════
-- Leaderboards / All-Stars / Trailblazers / MVP History / Prize Cart Budget
-- 2026-07-11 — Peter directive: wire competitive scaffolding into CPR
-- ═══════════════════════════════════════════════════════════════

-- 1. LEADERBOARDS — Gold / Silver / Bronze per category
-- Category enum: 'quarter_sp' | 'week_sp' | 'week_quotes'
-- Tier enum: 1=Gold, 2=Silver, 3=Bronze
CREATE TABLE IF NOT EXISTS public.leaderboards (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id             uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  category              text NOT NULL CHECK (category IN ('quarter_sp','week_sp','week_quotes')),
  tier                  int  NOT NULL CHECK (tier IN (1,2,3)),
  team_member_id        uuid NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,
  record_value          numeric NOT NULL,
  record_period_label   text NOT NULL,           -- 'Q3 2024' or '2026-03-07' etc.
  record_week_ending    date,                    -- for week_sp / week_quotes
  set_at                timestamptz NOT NULL DEFAULT now(),
  notes                 text,
  UNIQUE (agency_id, category, tier)
);

-- 2. ALL-STARS — running tally of times a person crossed the all-star floor
-- Floor is derived at read time: round(bronze) down to nearest N (100/50/5 per category)
CREATE TABLE IF NOT EXISTS public.all_star_counts (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id             uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  category              text NOT NULL CHECK (category IN ('quarter_sp','week_sp','week_quotes')),
  team_member_id        uuid NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,
  count                 int  NOT NULL DEFAULT 0,
  seeded_count          int  NOT NULL DEFAULT 0, -- historical seed (untracked crossings pre-system)
  last_crossing_at      timestamptz,             -- last time a new crossing was logged
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, category, team_member_id)
);

-- 3. ALL-STAR FLOOR CONFIG — rounding step per category
CREATE TABLE IF NOT EXISTS public.leaderboard_floor_config (
  category              text PRIMARY KEY CHECK (category IN ('quarter_sp','week_sp','week_quotes')),
  round_step            int  NOT NULL,           -- 100, 50, 5
  round_direction       text NOT NULL CHECK (round_direction IN ('floor','ceil')),
  description           text
);
INSERT INTO public.leaderboard_floor_config (category, round_step, round_direction, description) VALUES
  ('quarter_sp',   100, 'floor', 'Quarter SP all-star floor = bronze rounded down to nearest 100'),
  ('week_sp',      50,  'floor', 'Week SP all-star floor = bronze rounded down to nearest 50'),
  ('week_quotes',  5,   'floor', 'Week quotes all-star floor = bronze rounded down to nearest 5')
ON CONFLICT (category) DO UPDATE SET
  round_step = EXCLUDED.round_step,
  round_direction = EXCLUDED.round_direction,
  description = EXCLUDED.description;

-- 4. MVP HISTORY — every weekly MVP crowned (person + SP + draws)
CREATE TABLE IF NOT EXISTS public.mvp_history (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id             uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  week_ending_date      date NOT NULL,
  team_member_id        uuid NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,
  sales_points_earned   numeric NOT NULL,
  prize_draws           int NOT NULL DEFAULT 1,  -- 1/2/3 tiered by SP
  created_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, week_ending_date)          -- one MVP per week per agency
);

-- 5. TRAILBLAZER CROSSINGS — every threshold crossing gets a row
-- Trailblazer = FIRST to cross a threshold above current Gold. Threshold = Gold rounded UP by same step.
CREATE TABLE IF NOT EXISTS public.trailblazer_crossings (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id             uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  category              text NOT NULL CHECK (category IN ('quarter_sp','week_sp','week_quotes')),
  team_member_id        uuid NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,
  crossing_value        numeric NOT NULL,
  threshold_at_crossing numeric NOT NULL,
  period_label          text NOT NULL,
  week_ending           date,
  crossed_at            timestamptz NOT NULL DEFAULT now()
);

-- 6. QUARTER PRIZE BUDGETS — the total quarter-ending prize cart budget (not per-prize)
CREATE TABLE IF NOT EXISTS public.quarter_prize_budgets (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id             uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  quarter_ending_date   date NOT NULL,           -- e.g. 2026-10-03 for Q3 2026
  budget_dollars        numeric NOT NULL,
  formula_note          text,
  set_at                timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, quarter_ending_date)
);

-- RLS: standard anon-read pattern (matches other CPR-related tables)
ALTER TABLE public.leaderboards            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.all_star_counts         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.leaderboard_floor_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mvp_history             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trailblazer_crossings   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quarter_prize_budgets   ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='leaderboards' AND policyname='anon_read') THEN
    CREATE POLICY anon_read ON public.leaderboards FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='all_star_counts' AND policyname='anon_read') THEN
    CREATE POLICY anon_read ON public.all_star_counts FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='leaderboard_floor_config' AND policyname='anon_read') THEN
    CREATE POLICY anon_read ON public.leaderboard_floor_config FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='mvp_history' AND policyname='anon_read') THEN
    CREATE POLICY anon_read ON public.mvp_history FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='trailblazer_crossings' AND policyname='anon_read') THEN
    CREATE POLICY anon_read ON public.trailblazer_crossings FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='quarter_prize_budgets' AND policyname='anon_read') THEN
    CREATE POLICY anon_read ON public.quarter_prize_budgets FOR SELECT USING (true);
  END IF;
END $$;
