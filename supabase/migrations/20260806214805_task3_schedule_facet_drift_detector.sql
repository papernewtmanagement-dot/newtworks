SELECT cron.schedule(
  'hiregauge_facet_drift_monthly',
  '0 9 1 * *',
  $$SELECT public.hiregauge_detect_facet_input_drift();$$
);
