
-- ============================================================
-- Producer Complacency — internal recipe handler
-- ------------------------------------------------------------
-- Follows the run_internal_recipe() contract from migration 012:
--   handler signature: (p_agency_id UUID, p_recipe_id UUID) RETURNS jsonb
--   return shape:      jsonb_build_object('records_processed', n, 'output_summary', text)
-- ============================================================

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
  -- Iterate producers currently below baseline for this agency
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
    -- Dedupe: don't fire if there's already an open alert today with the same title
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

GRANT EXECUTE ON FUNCTION public.producer_complacency_check(UUID, UUID)
  TO postgres, service_role;

-- ============================================================
-- Wire the existing recipe to the INTERNAL dispatch path.
-- The recipe was previously registered without composio_action,
-- which would have caused the runner to error at L714 ("no composio_connection set").
-- ============================================================
UPDATE public.automation_recipes
SET composio_action = 'INTERNAL'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Producer Complacency Watcher'
  AND internal_handler = 'producer_complacency_check';

