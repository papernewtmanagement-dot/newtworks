CREATE TABLE IF NOT EXISTS public.producer_activity (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  team_member_id uuid NOT NULL REFERENCES public.team(id),
  period_year integer NOT NULL,
  period_month integer NOT NULL,
  activity_type text NOT NULL,
  count integer NOT NULL DEFAULT 0,
  source text NOT NULL,
  notes text,
  created_at timestamptz DEFAULT NOW(),
  updated_at timestamptz DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_producer_activity_member_period
  ON public.producer_activity (team_member_id, period_year, period_month);

CREATE INDEX IF NOT EXISTS idx_producer_activity_type
  ON public.producer_activity (activity_type);

COMMENT ON TABLE public.producer_activity IS 'Per-team-member activity counts (Reviews, Referrals, Appointments, Bank actions, $10 Bump events). Excludes quote-related data which lives in weekly_cpr_team_detail.';
COMMENT ON COLUMN public.producer_activity.activity_type IS 'Canonical values: review, appointment_set, appointment_kept_pivot_escalated, appointment_sold_pivot_escalated, referral_unsold, referral_sold, bank_account_opened, bank_account_closed, plus $10 bump events (monday_most_quotes, monday_first_app, monday_most_apps, win_the_week, all_star, record_breaker, trailblazer_milestone, one_percent_weekly_gain)';
