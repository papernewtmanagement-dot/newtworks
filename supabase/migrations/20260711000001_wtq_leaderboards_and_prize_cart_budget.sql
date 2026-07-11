-- 2026-07-11 wtq_leaderboards_and_prize_cart_budget
-- Six new tables for leaderboards / all-stars / MVP history / trailblazer crossings / quarter budgets.
-- Applied to production via Supabase MCP.
CREATE TABLE IF NOT EXISTS public.leaderboards (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  category text NOT NULL CHECK (category IN ('quarter_sp','week_sp','week_quotes')),
  tier smallint NOT NULL CHECK (tier IN (1,2,3)),
  team_member_id uuid NOT NULL,
  record_value numeric NOT NULL,
  record_period_label text NOT NULL,
  record_week_ending date,
  set_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, category, tier)
);
CREATE TABLE IF NOT EXISTS public.all_star_counts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  category text NOT NULL CHECK (category IN ('quarter_sp','week_sp','week_quotes')),
  team_member_id uuid NOT NULL,
  count integer NOT NULL DEFAULT 0,
  seeded_count integer NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, category, team_member_id)
);
CREATE TABLE IF NOT EXISTS public.leaderboard_floor_config (
  category text PRIMARY KEY,
  round_step numeric NOT NULL,
  round_direction text NOT NULL DEFAULT 'down',
  description text
);
CREATE TABLE IF NOT EXISTS public.mvp_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  week_ending_date date NOT NULL,
  team_member_id uuid NOT NULL,
  sales_points_earned numeric NOT NULL,
  prize_draws integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, week_ending_date)
);
CREATE TABLE IF NOT EXISTS public.trailblazer_crossings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  category text NOT NULL,
  team_member_id uuid NOT NULL,
  threshold_value numeric NOT NULL,
  actual_value numeric NOT NULL,
  crossed_at timestamptz NOT NULL DEFAULT now(),
  week_ending_date date
);
CREATE TABLE IF NOT EXISTS public.quarter_prize_budgets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  quarter_ending_date date NOT NULL,
  budget_dollars numeric NOT NULL,
  formula_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, quarter_ending_date)
);
ALTER TABLE public.leaderboards            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.all_star_counts         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.leaderboard_floor_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mvp_history             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trailblazer_crossings   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quarter_prize_budgets   ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  CREATE POLICY anon_read_leaderboards ON public.leaderboards FOR SELECT USING (true);
  CREATE POLICY anon_read_all_star_counts ON public.all_star_counts FOR SELECT USING (true);
  CREATE POLICY anon_read_floor_config ON public.leaderboard_floor_config FOR SELECT USING (true);
  CREATE POLICY anon_read_mvp_history ON public.mvp_history FOR SELECT USING (true);
  CREATE POLICY anon_read_trailblazer_crossings ON public.trailblazer_crossings FOR SELECT USING (true);
  CREATE POLICY anon_read_quarter_prize_budgets ON public.quarter_prize_budgets FOR SELECT USING (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
