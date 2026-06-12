-- ============================================================
-- MIGRATION 024 — Producer Complacency Early-Warning
-- ------------------------------------------------------------
-- Adds a leading indicator for producer complacency cycles.
-- Compares each active producer's trailing 2-month new P&C premium
-- average against their trailing 6-month baseline (the 4 months
-- preceding the recent 2). Fires an alert when recent < 90% of
-- baseline AND at least 4 months of data exist.
--
-- Specifically designed to catch John Kostov's known 1-2 quarter
-- complacency cycle BEFORE a full bad quarter lands on the books.
-- Applies generically to all active producers in new_business or
-- inside_sales roles.
--
-- Idempotent. Safe to re-run.
-- ============================================================

-- ----------------------------------------------------------------------
-- 1) View: trailing-window comparison per active producer
-- ----------------------------------------------------------------------
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


-- ----------------------------------------------------------------------
-- 2) General-purpose check function (cross-agency, ad-hoc use)
-- ----------------------------------------------------------------------
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


-- ----------------------------------------------------------------------
-- 3) Recipe handler (called by run_internal_recipe from migration 012)
--    Signature contract: (p_agency_id UUID, p_recipe_id UUID) RETURNS jsonb
--    Returns: jsonb_build_object('records_processed', n, 'output_summary', text)
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.producer_complacency_check(
  p_agency_id UUID,
  p_recipe_id UUID
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $func$
DECLARE
  v_inserted  integer := 0;
  v_names     text[]  := '{}';
  v_summary   text;
  r           RECORD;
BEGIN
  FOR r IN
    SELECT
      v.staff_id,
      v.producer_name,
      v.pct_change,
      v.avg_premium_recent_2mo,
      v.avg_premium_baseline_4mo
    FROM public.v_producer_complacency v
    WHERE v.agency_id = p_agency_id
      AND v.complacency_alert = true
  LOOP
    -- Dedupe: skip if an open alert with the same title already fired today
    IF NOT EXISTS (
      SELECT 1 FROM public.alerts a
      WHERE a.agency_id = p_agency_id
        AND a.is_resolved = false
        AND a.title = 'Producer complacency signal: ' || r.producer_name
        AND a.created_at >= date_trunc('day', now())
    ) THEN
      INSERT INTO public.alerts
        (agency_id, alert_type, severity, title, message,
         module_reference, related_id, is_read, is_resolved)
      VALUES
        (p_agency_id,
         'producer_complacency',
         'warning',
         'Producer complacency signal: ' || r.producer_name,
         r.producer_name || ' trailing 2-month average new P&C premium is '
           || ABS(r.pct_change) || '% below their trailing 4-month baseline ($'
           || r.avg_premium_recent_2mo || ' vs $' || r.avg_premium_baseline_4mo
           || '). Time for a check-in before the slip deepens into a full bad quarter.',
         'HR',
         r.staff_id,
         false,
         false);
      v_inserted := v_inserted + 1;
      v_names := v_names || r.producer_name;
    END IF;
  END LOOP;

  v_summary := CASE
    WHEN v_inserted = 0
      THEN 'No new complacency alerts. All producers within 10% of baseline (or already alerted today).'
    ELSE 'Fired complacency alerts for: ' || array_to_string(v_names, ', ')
  END;

  RETURN jsonb_build_object(
    'records_processed', v_inserted,
    'output_summary',    v_summary
  );
END;
$func$;


-- ----------------------------------------------------------------------
-- 4) Permissions
-- ----------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.producer_complacency_check(UUID, UUID)
  TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.check_producer_complacency()
  TO postgres, service_role, authenticated;


-- ----------------------------------------------------------------------
-- 5) Recipe registration — idempotent
--    Calls the handler weekly via run_internal_recipe()
-- ----------------------------------------------------------------------
INSERT INTO public.automation_recipes
  (agency_id, recipe_name, recipe_description, trigger_type,
   cron_expression, composio_action, internal_handler, is_active)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  'Producer Complacency Watcher',
  'Weekly check (Mondays 9am CT). Calls producer_complacency_check() handler which inserts an alert into public.alerts for any active new_business or inside_sales producer whose trailing 2-month new P&C premium average is more than 10% below their trailing 4-month baseline. Designed to catch John Kostov''s known 1-2 quarter complacency cycle early. Requires at least 4 months of data in producer_production before firing.',
  'schedule',
  '0 14 * * MON',
  'INTERNAL',
  'producer_complacency_check',
  true
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND recipe_name = 'Producer Complacency Watcher'
);

-- Backfill composio_action if recipe was registered before this migration
UPDATE public.automation_recipes
SET composio_action = 'INTERNAL'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Producer Complacency Watcher'
  AND internal_handler = 'producer_complacency_check'
  AND (composio_action IS NULL OR composio_action <> 'INTERNAL');
