ALTER TABLE public.weekly_cpr_reports
  ADD COLUMN IF NOT EXISTS wtw_quotes_restored int NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.weekly_cpr_reports.wtw_quotes_restored IS
  'Quotes bought back via the $10/quote Requirements Adjustment buy-back (locked 2026-08-15). '
  'Sum of individual restorations (licensed teammates buying back their own personal-minimum shortfall) '
  'plus any remaining team-level shortfall bought back from the shared bonus pool. Added on top of '
  'quotes_total_net (raw) when determining won_the_week and quotes_owed_next_week.';
