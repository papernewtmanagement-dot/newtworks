-- Pace targets for the daily/weekly/quarterly checkin comparison messages.
-- Rows only exist for role-levels that carry an individual requirement.
-- Anyone in a role-level without a row contributes to the team total but
-- does not add to the team requirement (e.g. Account Associates).

CREATE TABLE IF NOT EXISTS public.role_pace_targets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  role_category text NOT NULL,
  role_level text NOT NULL,
  quotes_per_week_target numeric NOT NULL CHECK (quotes_per_week_target >= 0),
  sales_points_per_quarter_target numeric NOT NULL CHECK (sales_points_per_quarter_target >= 0),
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, role_category, role_level)
);

COMMENT ON TABLE public.role_pace_targets IS
  'Per-(role_category, role_level) pace targets used by team checkin compile messages to compute the team requirement and compare to actual. Missing rows = no individual requirement; that role still contributes to team total.';

-- Seed targets
INSERT INTO public.role_pace_targets (
  agency_id, role_category, role_level,
  quotes_per_week_target, sales_points_per_quarter_target,
  notes
) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'Sales', 'Account Manager',
   15, 1000, 'AM Sales (Acquisition, Inside Sales) — current bearer of the requirement'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Retention', 'Account Manager',
   8, 500, 'AM Retention — no current team member at this level; seeded for when promoted/hired')
ON CONFLICT (agency_id, role_category, role_level) DO NOTHING;
