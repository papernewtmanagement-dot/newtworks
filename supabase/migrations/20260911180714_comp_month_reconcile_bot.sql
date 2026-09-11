-- The monthly close step "Reconcile COMP_RECAP to GL before closing" is now
-- done by the daily Monthly Close Monitor instead of waiting on a person.
-- It sat pending for June, July and August 2026 because nothing did it.
--
-- comp_month_reconcile checks one month:
--   1. Both halves of the month's comp statements are in (else: waiting).
--   2. Each statement ties to the deposit State Farm printed on it
--      (documents.stated_net_payable) = statement lines minus deductions.
--   3. Every comp record line is posted.
--   4. Every posted line that should hit the books has a ledger entry, for the
--      same amount (lines mapped to __SKIP__, e.g. credit union, are exempt).
--   5. No ledger entry points at a comp record line that no longer exists.
-- All clear: the checklist item is marked done with a one-line summary.
-- Anything wrong: a high alert naming each problem, repeated daily until fixed,
-- and cleared automatically once the month reconciles.

CREATE OR REPLACE FUNCTION public.comp_recap_row_skips_ledger(p_agency_id uuid, p_category text, p_description text)
RETURNS boolean LANGUAGE sql STABLE SET search_path TO 'public' AS $function$
  -- Same lookup order comp_gl_writer uses to pick an account.
  SELECT COALESCE((
    SELECT m.source_account_code = '__SKIP__' FROM (
      SELECT source_account_code, priority, description_pattern FROM comp_deduction_map
       WHERE agency_id = p_agency_id AND comp_category = p_category AND is_active AND COALESCE(p_category,'') LIKE 'deduction_%'
         AND source_account_code IS NOT NULL AND source_business_entity_id IS NOT NULL
         AND (description_pattern IS NULL OR (p_description IS NOT NULL AND p_description ~* description_pattern))
      UNION ALL
      SELECT source_account_code, priority, description_pattern FROM comp_category_map
       WHERE agency_id = p_agency_id AND comp_category = p_category AND is_active AND COALESCE(p_category,'') NOT LIKE 'deduction_%'
         AND source_account_code IS NOT NULL AND source_business_entity_id IS NOT NULL
         AND (description_pattern IS NULL OR (p_description IS NOT NULL AND p_description ~* description_pattern))
    ) m ORDER BY m.priority ASC, m.description_pattern NULLS LAST LIMIT 1), false);
$function$;

CREATE OR REPLACE FUNCTION public.comp_month_reconcile(p_agency_id uuid, p_year int, p_month int)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_halves int; v_problems text[] := '{}'; v_stmt record; v_n int; v_amt numeric;
  v_stmts int := 0; v_lines int := 0;
BEGIN
  SELECT count(DISTINCT comp_type) INTO v_halves FROM comp_recap
   WHERE agency_id = p_agency_id AND period_year = p_year AND period_month = p_month
     AND COALESCE(comp_category,'') NOT LIKE 'deduction_%' AND source_document_id IS NOT NULL;
  IF v_halves < 2 THEN
    RETURN jsonb_build_object('status', 'waiting', 'halves_in', v_halves);
  END IF;

  -- 2. Each statement ties to its printed deposit.
  FOR v_stmt IN
    SELECT cr.period_day,
      SUM(cr.amount) FILTER (WHERE COALESCE(cr.comp_category,'') NOT LIKE 'deduction_%') AS comp,
      COALESCE(SUM(cr.amount) FILTER (WHERE cr.comp_category LIKE 'deduction_%'), 0) AS ded,
      (SELECT MAX(d.stated_net_payable) FROM documents d WHERE d.id IN (
         SELECT x.source_document_id FROM comp_recap x WHERE x.agency_id = p_agency_id AND x.period_year = p_year
            AND x.period_month = p_month AND x.period_day = cr.period_day
            AND COALESCE(x.comp_category,'') NOT LIKE 'deduction_%')) AS stated
    FROM comp_recap cr
    WHERE cr.agency_id = p_agency_id AND cr.period_year = p_year AND cr.period_month = p_month
    GROUP BY cr.period_day
    HAVING COUNT(*) FILTER (WHERE COALESCE(cr.comp_category,'') NOT LIKE 'deduction_%') > 0
  LOOP
    v_stmts := v_stmts + 1;
    IF v_stmt.stated IS NULL THEN
      v_problems := v_problems || format('Statement ending %s/%s has no printed deposit on file.', p_month, v_stmt.period_day);
    ELSIF abs(v_stmt.stated - (v_stmt.comp - v_stmt.ded)) >= 0.01 THEN
      v_problems := v_problems || format('Statement ending %s/%s: State Farm deposited %s, comp records come to %s.',
        p_month, v_stmt.period_day, to_char(v_stmt.stated, 'FM$999,999,990.00'), to_char(v_stmt.comp - v_stmt.ded, 'FM$999,999,990.00'));
    END IF;
  END LOOP;

  SELECT count(*) INTO v_lines FROM comp_recap WHERE agency_id = p_agency_id AND period_year = p_year AND period_month = p_month;

  -- 3. Unposted lines.
  SELECT count(*), COALESCE(sum(amount),0) INTO v_n, v_amt FROM comp_recap
   WHERE agency_id = p_agency_id AND period_year = p_year AND period_month = p_month AND posted_at IS NULL AND amount <> 0;
  IF v_n > 0 THEN
    v_problems := v_problems || format('%s comp line(s) not posted to the books (%s).', v_n, to_char(v_amt, 'FM$999,999,990.00'));
  END IF;

  -- 4. Posted lines missing from the ledger, or posted for the wrong amount.
  SELECT count(*), COALESCE(sum(cr.amount),0) INTO v_n, v_amt FROM comp_recap cr
   WHERE cr.agency_id = p_agency_id AND cr.period_year = p_year AND cr.period_month = p_month
     AND cr.posted_at IS NOT NULL AND cr.amount <> 0
     AND NOT EXISTS (SELECT 1 FROM ledger l WHERE l.comp_recap_id = cr.id)
     AND NOT public.comp_recap_row_skips_ledger(p_agency_id, cr.comp_category, cr.description);
  IF v_n > 0 THEN
    v_problems := v_problems || format('%s comp line(s) marked posted but not in the ledger (%s).', v_n, to_char(v_amt, 'FM$999,999,990.00'));
  END IF;

  SELECT count(*) INTO v_n FROM comp_recap cr
   WHERE cr.agency_id = p_agency_id AND cr.period_year = p_year AND cr.period_month = p_month
     AND EXISTS (SELECT 1 FROM ledger l WHERE l.comp_recap_id = cr.id)
     AND abs((SELECT sum(l.debit + l.credit) FROM ledger l WHERE l.comp_recap_id = cr.id) - abs(cr.amount)) >= 0.01;
  IF v_n > 0 THEN
    v_problems := v_problems || format('%s comp line(s) in the ledger for a different amount than the statement.', v_n);
  END IF;

  -- 5. Ledger entries left behind by a comp line that was deleted.
  SELECT count(*), COALESCE(sum(l.credit - l.debit),0) INTO v_n, v_amt FROM ledger l
   WHERE l.agency_id = p_agency_id AND l.comp_recap_id IS NOT NULL
     AND l.entry_date >= make_date(p_year, p_month, 1) AND l.entry_date < make_date(p_year, p_month, 1) + INTERVAL '1 month'
     AND NOT EXISTS (SELECT 1 FROM comp_recap cr WHERE cr.id = l.comp_recap_id);
  IF v_n > 0 THEN
    v_problems := v_problems || format('%s ledger entr(ies) point at comp lines that no longer exist (net %s).', v_n, to_char(v_amt, 'FM$999,999,990.00'));
  END IF;

  IF array_length(v_problems, 1) IS NULL THEN
    RETURN jsonb_build_object('status', 'ok',
      'summary', format('Auto-reconciled %s: %s statements tie to their deposits, all %s comp lines are in the ledger.',
                        to_char(make_date(p_year, p_month, 1), 'Mon YYYY'), v_stmts, v_lines));
  END IF;
  RETURN jsonb_build_object('status', 'problems', 'problems', to_jsonb(v_problems));
END;
$function$;

-- Wire it into the Monthly Close Monitor (daily).
DO $$
DECLARE v_def text; v_pairs text[][] := ARRAY[
  [$q$  v_new_doc      uuid;$q$,
   $q$  v_new_doc      uuid;
  v_rec          jsonb;$q$],
  [$q$    SELECT id, period_year, period_month, doc_category, status, received_at, document_id
    FROM public.monthly_close_checklist$q$,
   $q$    SELECT id, period_year, period_month, doc_category, doc_label, status, received_at, document_id
    FROM public.monthly_close_checklist$q$],
  [$q$      AND doc_category IN ('comp_recap_daily','deduction_statement','payroll')$q$,
   $q$      AND doc_category IN ('comp_recap_daily','deduction_statement','payroll','reconciliation')$q$],
  [$q$    END IF;

    -- Apply only if it advances the row (never downgrade).$q$,
   $q$    ELSIF v_chk.doc_category = 'reconciliation' AND v_chk.doc_label ILIKE 'Reconcile COMP_RECAP to GL%' THEN
      -- Comp-to-books reconciliation, done by this monitor (added 2026-09-11).
      v_rec := public.comp_month_reconcile(p_agency_id, v_chk.period_year, v_chk.period_month);
      IF v_rec->>'status' = 'ok' THEN
        v_new_status := 'received';
        UPDATE public.monthly_close_checklist SET notes = v_rec->>'summary' WHERE id = v_chk.id;
      ELSIF v_rec->>'status' = 'problems' THEN
        INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved, created_at)
        SELECT p_agency_id, 'reconciliation_mismatch', 'high',
               'Comp records do not reconcile for ' || to_char(make_date(v_chk.period_year, v_chk.period_month, 1), 'Mon YYYY'),
               (SELECT string_agg(p, ' ') FROM jsonb_array_elements_text(v_rec->'problems') p),
               'monthly_close_monitor:' || v_chk.id::text, false, false, NOW()
        WHERE NOT EXISTS (
          SELECT 1 FROM public.alerts WHERE agency_id = p_agency_id
            AND module_reference = 'monthly_close_monitor:' || v_chk.id::text
            AND alert_type = 'reconciliation_mismatch' AND is_resolved = false AND created_at::date = v_today);
        v_overdue_count := v_overdue_count + 1;
      END IF;
    END IF;

    -- Apply only if it advances the row (never downgrade).$q$],
  [$q$     AND a.alert_type = 'overdue_close_item'$q$,
   $q$     AND a.alert_type IN ('overdue_close_item', 'reconciliation_mismatch')$q$]
]; i int;
BEGIN
  v_def := pg_get_functiondef('public.monthly_close_monitor(uuid,uuid)'::regprocedure);
  FOR i IN 1 .. array_length(v_pairs, 1) LOOP
    IF (length(v_def) - length(replace(v_def, v_pairs[i][1], ''))) / length(v_pairs[i][1]) <> 1 THEN
      RAISE EXCEPTION 'monthly_close_monitor anchor % not found exactly once', i;
    END IF;
    v_def := replace(v_def, v_pairs[i][1], v_pairs[i][2]);
  END LOOP;
  EXECUTE v_def;
END $$;