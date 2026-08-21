CREATE OR REPLACE FUNCTION public.monthly_close_monitor(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_today        DATE := CURRENT_DATE;
  v_matched      INTEGER := 0;
  v_overdue_count INTEGER := 0;
  v_resolved_count INTEGER := 0;
  v_overdue      RECORD;
  v_chk          RECORD;
  -- comp aggregates
  v_comp_rows    INTEGER;  v_comp_halves INTEGER;  v_comp_doc uuid;
  v_ded_rows     INTEGER;  v_ded_halves  INTEGER;  v_ded_doc uuid;
  -- payroll aggregates
  v_pay_rows     INTEGER;  v_pay_lastweek INTEGER; v_pay_doc uuid;
  v_last_day_of_period DATE;
  v_new_status   TEXT;
  v_new_doc      uuid;
BEGIN
  -- =====================================================================
  -- AUTO-MATCH: populate status / received_at / document_id from source
  -- data for every OPEN (not is_closed) checklist row across all periods.
  -- Rules (locked):
  --   * comp_recap_daily : comp_recap rows for period, comp_category NOT LIKE 'deduction_%'.
  --       both halves (1H+2H) present -> received ; one half -> partial.
  --   * deduction_statement : same but comp_category LIKE 'deduction_%'.
  --   * payroll : payroll_runs with pay_date in month AND source_document_id NOT NULL.
  --       a run dated in the final 7 days of the month -> received ; else partial.
  --   document_id = source_document_id of the most-recently-processed contributing doc.
  -- SAFETY: never downgrade. Only advance pending->partial/received or
  --   partial->received. Never touch a row the agent already marked received,
  --   and never touch is_closed rows.
  -- =====================================================================
  FOR v_chk IN
    SELECT id, period_year, period_month, doc_category, status, received_at, document_id
    FROM public.monthly_close_checklist
    WHERE agency_id = p_agency_id
      AND is_closed = false
      AND status IS DISTINCT FROM 'received'
      AND doc_category IN ('comp_recap_daily','deduction_statement','payroll')
  LOOP
    v_new_status := NULL;
    v_new_doc := NULL;
    v_last_day_of_period :=
      (make_date(v_chk.period_year, v_chk.period_month, 1) + INTERVAL '1 month - 1 day')::date;

    IF v_chk.doc_category = 'comp_recap_daily' THEN
      SELECT count(*),
             count(DISTINCT comp_type),
             (SELECT cr2.source_document_id
                FROM public.comp_recap cr2
                JOIN public.documents d2 ON d2.id = cr2.source_document_id
               WHERE cr2.agency_id = p_agency_id
                 AND cr2.period_year = v_chk.period_year
                 AND cr2.period_month = v_chk.period_month
                 AND cr2.comp_category NOT LIKE 'deduction_%'
                 AND cr2.source_document_id IS NOT NULL
               ORDER BY d2.processed_at DESC NULLS LAST
               LIMIT 1)
        INTO v_comp_rows, v_comp_halves, v_comp_doc
      FROM public.comp_recap cr
      WHERE cr.agency_id = p_agency_id
        AND cr.period_year = v_chk.period_year
        AND cr.period_month = v_chk.period_month
        AND cr.comp_category NOT LIKE 'deduction_%';
      IF v_comp_rows > 0 THEN
        v_new_status := CASE WHEN v_comp_halves >= 2 THEN 'received' ELSE 'partial' END;
        v_new_doc := v_comp_doc;
      END IF;

    ELSIF v_chk.doc_category = 'deduction_statement' THEN
      SELECT count(*),
             count(DISTINCT comp_type),
             (SELECT cr2.source_document_id
                FROM public.comp_recap cr2
                JOIN public.documents d2 ON d2.id = cr2.source_document_id
               WHERE cr2.agency_id = p_agency_id
                 AND cr2.period_year = v_chk.period_year
                 AND cr2.period_month = v_chk.period_month
                 AND cr2.comp_category LIKE 'deduction_%'
                 AND cr2.source_document_id IS NOT NULL
               ORDER BY d2.processed_at DESC NULLS LAST
               LIMIT 1)
        INTO v_ded_rows, v_ded_halves, v_ded_doc
      FROM public.comp_recap cr
      WHERE cr.agency_id = p_agency_id
        AND cr.period_year = v_chk.period_year
        AND cr.period_month = v_chk.period_month
        AND cr.comp_category LIKE 'deduction_%';
      IF v_ded_rows > 0 THEN
        v_new_status := CASE WHEN v_ded_halves >= 2 THEN 'received' ELSE 'partial' END;
        v_new_doc := v_ded_doc;
      END IF;

    ELSIF v_chk.doc_category = 'payroll' THEN
      SELECT count(*),
             count(*) FILTER (WHERE pr.pay_date >= v_last_day_of_period - INTERVAL '6 days'),
             (SELECT pr2.source_document_id
                FROM public.payroll_runs pr2
               WHERE pr2.agency_id = p_agency_id
                 AND pr2.pay_date >= make_date(v_chk.period_year, v_chk.period_month, 1)
                 AND pr2.pay_date <= v_last_day_of_period
                 AND pr2.source_document_id IS NOT NULL
               ORDER BY pr2.pay_date DESC
               LIMIT 1)
        INTO v_pay_rows, v_pay_lastweek, v_pay_doc
      FROM public.payroll_runs pr
      WHERE pr.agency_id = p_agency_id
        AND pr.pay_date >= make_date(v_chk.period_year, v_chk.period_month, 1)
        AND pr.pay_date <= v_last_day_of_period
        AND pr.source_document_id IS NOT NULL;
      IF v_pay_rows > 0 THEN
        v_new_status := CASE WHEN v_pay_lastweek > 0 THEN 'received' ELSE 'partial' END;
        v_new_doc := v_pay_doc;
      END IF;
    END IF;

    -- Apply only if it advances the row (never downgrade).
    IF v_new_status IS NOT NULL
       AND ( (v_chk.status = 'pending')
          OR (v_chk.status = 'partial' AND v_new_status = 'received') ) THEN
      UPDATE public.monthly_close_checklist
         SET status = v_new_status,
             document_id = COALESCE(v_new_doc, document_id),
             received_at = COALESCE(received_at, CURRENT_DATE)
       WHERE id = v_chk.id;
      v_matched := v_matched + 1;
    ELSIF v_new_status IS NOT NULL AND v_new_doc IS NOT NULL AND v_chk.document_id IS NULL THEN
      -- status unchanged but we can backfill a now-known source document link
      UPDATE public.monthly_close_checklist
         SET document_id = v_new_doc
       WHERE id = v_chk.id;
      v_matched := v_matched + 1;
    END IF;
  END LOOP;

  -- =====================================================================
  -- AUTO-RESOLVE STALE ALERTS (added 2026-05-28):
  -- Any unresolved overdue_close_item alert whose underlying checklist row
  -- is now 'received' or is_closed gets resolved automatically. This makes
  -- the monitor self-healing: when a document arrives and the auto-match
  -- block above flips the item to received, the prior days' overdue alerts
  -- for that item retract themselves instead of lingering as noise.
  -- Matching is by the module_reference convention 'monthly_close_monitor:<checklist_id>'.
  -- =====================================================================
  WITH satisfied AS (
    SELECT 'monthly_close_monitor:' || id::text AS modref
    FROM public.monthly_close_checklist
    WHERE agency_id = p_agency_id
      AND (status = 'received' OR is_closed = true)
  )
  UPDATE public.alerts a
     SET is_resolved = true, resolved_at = NOW()
   WHERE a.agency_id = p_agency_id
     AND a.alert_type = 'overdue_close_item'
     AND a.is_resolved = false
     AND a.module_reference IN (SELECT modref FROM satisfied);
  GET DIAGNOSTICS v_resolved_count = ROW_COUNT;

  -- =====================================================================
  -- OVERDUE ALERTS (preserved from v1): from the 5th onward, raise a
  -- warning alert (deduped per item per day) for current-month items that
  -- are past expected_by and still not received.
  -- =====================================================================
  IF EXTRACT(DAY FROM v_today)::INT >= 5 THEN
    FOR v_overdue IN
      SELECT id, doc_label FROM public.monthly_close_checklist
      WHERE agency_id = p_agency_id
        AND period_year = EXTRACT(YEAR FROM v_today)::INT
        AND period_month = EXTRACT(MONTH FROM v_today)::INT
        AND status IS DISTINCT FROM 'received'
        AND is_closed = false
        AND expected_by IS NOT NULL AND expected_by < v_today
    LOOP
      INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved, created_at)
      SELECT p_agency_id, 'overdue_close_item', 'warning',
             'Monthly close item overdue: ' || v_overdue.doc_label,
             'Item from this month''s close checklist is past its expected_by date.',
             'monthly_close_monitor:' || v_overdue.id::text, false, false, NOW()
      WHERE NOT EXISTS (
        SELECT 1 FROM public.alerts WHERE agency_id = p_agency_id
          AND module_reference = 'monthly_close_monitor:' || v_overdue.id::text
          AND is_resolved = false AND created_at::date = v_today
      );
      v_overdue_count := v_overdue_count + 1;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'records_processed', v_matched + v_overdue_count + v_resolved_count,
    'output_summary', v_matched || ' checklist items auto-matched, '
                      || v_resolved_count || ' stale alerts auto-resolved, '
                      || v_overdue_count || ' overdue alerts raised'
  );
END;
$function$;
