-- Add sales_points_v2 to weekly_cpr_team_detail
-- Backfill quarter-end Saturdays (2023 Q1 through 2026 Q2) with SP totals
-- computed under new structure (sf_builder_2026_07_07) via v_team_sales_points_quarterly

-- Step 1: new column
ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS sales_points_v2 numeric;

COMMENT ON COLUMN public.weekly_cpr_team_detail.sales_points_v2 IS
  'Quarterly sales points under new comp structure (sf_builder_2026_07_07). Populated only on the last Saturday of each calendar quarter (last Sat <= quarter_last_day). Backfilled 2026-07-08 from producer_production via v_team_sales_points_quarterly.';

-- Step 2: insert quarter-end CPR report rows that don't exist yet (2023 Q1 through 2026 Q1; Q2 2026 exists)
WITH quarters AS (
  SELECT
    y AS period_year,
    q AS quarter_num,
    (make_date(y, q*3, 1) + interval '1 month' - interval '1 day')::date AS quarter_last_day
  FROM generate_series(2023, 2026) y
  CROSS JOIN generate_series(1, 4) q
),
qs AS (
  SELECT
    period_year, quarter_num,
    (quarter_last_day - ((EXTRACT(dow FROM quarter_last_day)::int + 1) % 7) * interval '1 day')::date AS week_ending_date
  FROM quarters
  WHERE (period_year * 10 + quarter_num) <= 20262  -- through 2026 Q2
)
INSERT INTO public.weekly_cpr_reports (agency_id, week_ending_date, notes)
SELECT
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  week_ending_date,
  'Historical quarter-end backfill for sales_points_v2 (2026-07-08). No operational CPR fields populated.'
FROM qs
ON CONFLICT (agency_id, week_ending_date) DO NOTHING;

-- Step 3: upsert team_detail rows with sales_points_v2 from the view
WITH src AS (
  SELECT
    v.team_member_id,
    v.sales_points AS sp_v2,
    (make_date(v.period_year, v.quarter_num*3, 1) + interval '1 month' - interval '1 day')::date AS quarter_last_day
  FROM public.v_team_sales_points_quarterly v
  WHERE v.agency_id = '126794dd-25ff-47d2-a436-724499733365'
),
mapped AS (
  SELECT
    src.team_member_id,
    src.sp_v2,
    (src.quarter_last_day - ((EXTRACT(dow FROM src.quarter_last_day)::int + 1) % 7) * interval '1 day')::date AS week_ending_date
  FROM src
)
INSERT INTO public.weekly_cpr_team_detail
  (agency_id, weekly_cpr_report_id, team_member_id, quotes_modified, sales_points_v2)
SELECT
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  r.id,
  m.team_member_id,
  0,
  m.sp_v2
FROM mapped m
JOIN public.weekly_cpr_reports r
  ON r.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND r.week_ending_date = m.week_ending_date
ON CONFLICT (weekly_cpr_report_id, team_member_id)
DO UPDATE SET sales_points_v2 = EXCLUDED.sales_points_v2, updated_at = now();
