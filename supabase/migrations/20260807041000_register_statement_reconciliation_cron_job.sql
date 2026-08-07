SELECT cron.schedule(
  'statement_reconciliation_weekly',
  '0 13 * * 0',  -- 07:00 America/Chicago = 13:00 UTC (matches suspense_aging_daily's UTC-offset convention)
  $$SELECT public.fn_check_statement_reconciliation();$$
);
