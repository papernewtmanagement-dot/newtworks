
-- ============================================================
-- Producer Complacency Early-Warning Infrastructure
-- ============================================================
-- Compares each active producer's trailing 2-month new P&C premium
-- average to their trailing 6-month baseline (the 4 months preceding
-- the recent 2). Fires an alert when recent < 90% of baseline.
-- Designed to catch John Kostov's known 1-2 quarter complacency cycle
-- before a full bad quarter lands on the books.
-- ============================================================

CREATE OR REPLACE VIEW public.v_producer_complacency AS
WITH periods AS (
  SELECT
    pp.staff_id,
    pp.agency_id,
    COALESCE(SUM(pp.premium_issued) FILTER (
      WHERE make_date(pp.period_year, pp.period_month, 1)
            >= date_trunc('month', CURRENT_DATE - INTERVAL '2 months')
        AND make_date(pp.period_year, pp.period_month, 1)
            <  date_trunc('month', CURRENT_DATE)
    ), 0) / 2.0 AS avg_recent_2mo,
    COALESCE(SUM(pp.premium_issued) FILTER (
      WHERE make_date(pp.period_year, pp.period_month, 1)
            >= date_trunc('month', CURRENT_DATE - INTERVAL '6 months')
        AND make_date(pp.period_year, pp.period_month, 1)
            <  date_trunc('month', CURRENT_DATE - INTERVAL '2 months')
    ), 0) / 4.0 AS avg_baseline_4mo,
    COUNT(*) FILTER (
      WHERE make_date(pp.period_year, pp.period_month, 1)
            >= date_trunc('month', CURRENT_DATE - INTERVAL '6 months')
    ) AS data_points_available
  FROM public.producer_production pp
  WHERE pp.premium_type = 'new'
  GROUP BY pp.staff_id, pp.agency_id
)
SELECT
  s.id AS staff_id,
  s.agency_id,
  s.first_name || ' ' || s.last_name AS producer_name,
  s.primary_function,
  s.complacency_risk,
  ROUND(p.avg_recent_2mo::numeric, 2) AS avg_premium_recent_2mo,
  ROUND(p.avg_baseline_4mo::numeric, 2) AS avg_premium_baseline_4mo,
  CASE
    WHEN p.avg_baseline_4mo > 0
    THEN ROUND(((p.avg_recent_2mo - p.avg_baseline_4mo) / p.avg_baseline_4mo * 100)::numeric, 1)
    ELSE NULL
  END AS pct_change,
  COALESCE(p.data_points_available, 0) AS data_points_available,
  CASE
    WHEN p.avg_baseline_4mo > 0
     AND p.avg_recent_2mo < (p.avg_baseline_4mo * 0.90)
     AND COALESCE(p.data_points_available, 0) >= 4
    THEN true
    ELSE false
  END AS complacency_alert,
  CURRENT_DATE AS as_of_date
FROM public.staff s
LEFT JOIN periods p ON p.staff_id = s.id
WHERE s.is_active = true
  AND s.primary_function IN ('new_business', 'inside_sales');

-- Helper function for the automation runner to call.
-- Returns one row per producer who currently triggers the alert.
CREATE OR REPLACE FUNCTION public.check_producer_complacency()
RETURNS TABLE (
  staff_id uuid,
  agency_id uuid,
  producer_name text,
  pct_change numeric,
  recent_avg numeric,
  baseline_avg numeric,
  alert_title text,
  alert_message text
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    v.staff_id,
    v.agency_id,
    v.producer_name,
    v.pct_change,
    v.avg_premium_recent_2mo,
    v.avg_premium_baseline_4mo,
    'Producer complacency signal: ' || v.producer_name AS alert_title,
    v.producer_name || ' trailing 2-month average new P&C premium is '
      || ABS(v.pct_change) || '% below their trailing 4-month baseline ($'
      || v.avg_premium_recent_2mo || ' vs $' || v.avg_premium_baseline_4mo
      || '). Time for a check-in before the slip deepens into a full bad quarter.' AS alert_message
  FROM public.v_producer_complacency v
  WHERE v.complacency_alert = true;
$$;

-- Register the automation recipe shell.
-- internal_handler 'producer_complacency_check' needs to be wired into
-- the automation-runner Edge Function (small addition — see notes).
INSERT INTO public.automation_recipes
  (agency_id, recipe_name, recipe_description, trigger_type,
   cron_expression, internal_handler, is_active)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  'Producer Complacency Watcher',
  'Weekly check (Mondays 9am CT). Calls check_producer_complacency() and writes an alert to public.alerts for any active producer whose trailing 2-month new P&C premium average is more than 10% below their trailing 4-month baseline. Built to catch John Kostov''s known 1-2 quarter complacency cycle early; applies to all active new_business and inside_sales producers. Requires at least 4 data points to fire. Reads producer_production (currently empty — alert begins firing once Producer Production Report Processor populates the table).',
  'schedule',
  '0 14 * * MON',
  'producer_complacency_check',
  true
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND recipe_name = 'Producer Complacency Watcher'
);

