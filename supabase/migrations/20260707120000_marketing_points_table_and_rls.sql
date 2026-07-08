-- Marketing points table — Peter feeds weekly, function splits pool by share
CREATE TABLE IF NOT EXISTS public.marketing_points (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id UUID NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  team_member_id UUID NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,
  week_end_date DATE NOT NULL,
  points NUMERIC NOT NULL DEFAULT 0 CHECK (points >= 0),
  points_reviews NUMERIC DEFAULT 0 CHECK (points_reviews >= 0),
  points_referrals_quoted NUMERIC DEFAULT 0 CHECK (points_referrals_quoted >= 0),
  points_referrals_sold NUMERIC DEFAULT 0 CHECK (points_referrals_sold >= 0),
  notes TEXT,
  source TEXT DEFAULT 'peter_weekly_input',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (agency_id, team_member_id, week_end_date)
);

CREATE INDEX IF NOT EXISTS idx_marketing_points_lookup
  ON public.marketing_points (agency_id, week_end_date DESC);

CREATE INDEX IF NOT EXISTS idx_marketing_points_person
  ON public.marketing_points (agency_id, team_member_id, week_end_date);

ALTER TABLE public.marketing_points ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS marketing_points_anon_read ON public.marketing_points;
CREATE POLICY marketing_points_anon_read ON public.marketing_points
  FOR SELECT USING (true);

DROP POLICY IF EXISTS marketing_points_auth_write ON public.marketing_points;
CREATE POLICY marketing_points_auth_write ON public.marketing_points
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

COMMENT ON TABLE public.marketing_points IS
  'Weekly marketing points per team member. Peter inputs via chat with Claude. '
  'Feeds compute_weekly_marketing_bonus. 1 point = 1 review OR 1 referral quoted OR 1 referral sold. '
  'Full-cycle referral (quoted + sold) earns 2 points.';
