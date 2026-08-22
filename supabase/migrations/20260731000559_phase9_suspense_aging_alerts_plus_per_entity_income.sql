-- Phase 9: suspense aging alerts + per-entity unclassified income buckets.
--
-- Two parts:
--   (1) Add 0002 Unclassified Income to entities missing it (Eriosto, PaperNewt,
--       Personal, Steward). PSS already has one. Per Peter directive: every entity
--       gets one unclassified income + one unclassified expense bucket.
--   (2) Aging alert on suspense codes (0001-0005) — nag when any category holds
--       activity older than 30 days. Yellow 30-60d, red 60+d.

--------------------------------------------------------------------------------
-- Part 1: Add missing per-entity 0002 Unclassified Income rows
--------------------------------------------------------------------------------

INSERT INTO chart_of_accounts (
  agency_id, business_entity_id, account_code, account_name,
  account_type, account_subtype, is_active, is_system
)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'b5555555-5555-5555-5555-555555555555',
   '0002', '*Unclassified Income', 'income', 'suspense', true, false),  -- Eriosto
  ('126794dd-25ff-47d2-a436-724499733365', 'b1111111-1111-1111-1111-111111111111',
   '0002', '*Unclassified Income', 'income', 'suspense', true, false),  -- PaperNewt LLC
  ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333',
   '0002', '*Unclassified Income', 'income', 'suspense', true, false),  -- Personal
  ('126794dd-25ff-47d2-a436-724499733365', 'b4444444-4444-4444-4444-444444444444',
   '0002', '*Unclassified Income', 'income', 'suspense', true, false); -- Steward

--------------------------------------------------------------------------------
-- Part 2: Aging check function
--------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.check_suspense_aging(p_agency_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_created int := 0;
  v_resolved int := 0;
  v_row record;
BEGIN
  -- Clear stale suspense-aging alerts first; recompute today's picture from scratch.
  WITH bumped AS (
    UPDATE alerts
    SET is_resolved = true, resolved_at = NOW()
    WHERE agency_id = p_agency_id
      AND alert_type = 'suspense_aging'
      AND is_resolved IS NOT TRUE
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_resolved FROM bumped;

  FOR v_row IN
    SELECT
      coa.id AS coa_id,
      coa.account_code,
      coa.account_name,
      be.name AS entity_name,
      COUNT(jl.id) AS line_count,
      ROUND(SUM(COALESCE(jl.debit,0) - COALESCE(jl.credit,0))::numeric, 2) AS net_amount,
      MIN(je.entry_date) AS oldest_date,
      (CURRENT_DATE - MIN(je.entry_date)) AS age_days
    FROM chart_of_accounts coa
    JOIN business_entities be ON be.id = coa.business_entity_id
    JOIN journal_lines jl ON jl.account_id = coa.id
    JOIN journal_entries je ON je.id = jl.journal_entry_id
    WHERE coa.agency_id = p_agency_id
      AND coa.account_subtype = 'suspense'
      AND coa.is_active = true
    GROUP BY coa.id, coa.account_code, coa.account_name, be.name
    HAVING (CURRENT_DATE - MIN(je.entry_date)) > 30
       AND ROUND(SUM(COALESCE(jl.debit,0) - COALESCE(jl.credit,0))::numeric, 2) <> 0
  LOOP
    INSERT INTO alerts (
      agency_id, module_reference, alert_type, severity,
      title, message, related_id, is_resolved, is_read
    ) VALUES (
      p_agency_id,
      'financials',
      'suspense_aging',
      CASE WHEN v_row.age_days > 60 THEN 'high' ELSE 'medium' END,
      format('%s in %s aging %s days ($%s)',
             v_row.account_name, v_row.entity_name,
             v_row.age_days, v_row.net_amount),
      format('Oldest line: %s. %s lines totaling $%s. Categorize before month-end close.',
             v_row.oldest_date, v_row.line_count, v_row.net_amount),
      v_row.coa_id,
      false,
      false
    );
    v_created := v_created + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'alerts_created', v_created,
    'stale_alerts_resolved', v_resolved,
    'checked_at', NOW()
  );
END;
$$;

--------------------------------------------------------------------------------
-- Part 3: Schedule daily at 8am America/Chicago (13:00 UTC during CDT)
--------------------------------------------------------------------------------

-- Guard: unschedule if it somehow already exists (idempotent re-apply)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'suspense_aging_daily') THEN
    PERFORM cron.unschedule('suspense_aging_daily');
  END IF;
END $$;

SELECT cron.schedule(
  'suspense_aging_daily',
  '0 13 * * *',
  $CRON$ SELECT public.check_suspense_aging('126794dd-25ff-47d2-a436-724499733365'::uuid); $CRON$
);
