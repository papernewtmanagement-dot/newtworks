-- Retire the alerts table, part 1 of 3.
-- Peter ruling 2026-09-16: the alerts page is 90% machine log and he never
-- reads it. Financial exception checks move onto the Financials
-- Reconciliation tab, computed live. People watchers write a task instead.
-- Nothing here reads or writes public.alerts any more.

CREATE OR REPLACE VIEW public.v_dormant_gl_rules AS
SELECT
  r.id                AS rule_id,
  r.agency_id,
  r.rule_name,
  r.created_at,
  r.last_used_at,
  COALESCE(r.historical_uses, 0) AS historical_uses,
  CASE WHEN r.last_used_at IS NOT NULL THEN 'went_quiet' ELSE 'never_fired' END AS finding
FROM public.gl_classification_rules r
WHERE r.is_active = TRUE
  AND r.created_at < now() - interval '30 days'
  AND (
    (r.last_used_at IS NOT NULL AND r.last_used_at < now() - interval '30 days')
    OR (r.last_used_at IS NULL AND COALESCE(r.historical_uses, 0) = 0)
  );

CREATE OR REPLACE VIEW public.v_not_on_statement AS
SELECT
  l.agency_id,
  'posted'::text                AS finding,
  ra.id                         AS account_id,
  ra.account_name,
  sb.id                         AS statement_balance_id,
  sb.statement_period_start,
  sb.statement_period_end,
  count(*)                      AS n,
  sum(CASE WHEN l.debit > 0 THEN l.debit ELSE l.credit END) AS total_amount
FROM public.ledger l
JOIN public.cash_register_preliminary c ON c.id = l.cash_register_id
JOIN public.accounts ra ON (ra.account_number_last4 = c.account_last4 OR c.account_last4 = ANY(ra.alternate_last4s))
JOIN public.statement_balances sb ON sb.agency_id = l.agency_id
  AND (sb.account_last4 = ra.account_number_last4 OR sb.account_last4 = ANY(COALESCE(ra.alternate_last4s, ARRAY[]::text[])))
  AND l.entry_date BETWEEN sb.statement_period_start AND sb.statement_period_end
WHERE l.cash_register_id IS NOT NULL
  AND l.statement_id IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.statements s
    WHERE s.agency_id = l.agency_id AND s.account_id = ra.id
      AND s.excluded_from_ledger IS TRUE
      AND round(abs(s.amount),2) = round(CASE WHEN l.debit > 0 THEN l.debit ELSE l.credit END,2)
      AND (CASE WHEN s.transaction_type IN ('withdrawal','charge','debit') THEN 'debit'
                WHEN s.transaction_type IN ('deposit','payment_or_credit','credit','payment') THEN 'credit'
                ELSE NULL END) = (CASE WHEN l.debit > 0 THEN 'debit' ELSE 'credit' END)
      AND abs(s.transaction_date - l.entry_date) <= 4
  )
GROUP BY l.agency_id, ra.id, ra.account_name, sb.id, sb.statement_period_start, sb.statement_period_end
UNION ALL
SELECT
  c.agency_id,
  'possible_transfer'::text     AS finding,
  ra.id                         AS account_id,
  ra.account_name,
  sb.id                         AS statement_balance_id,
  sb.statement_period_start,
  sb.statement_period_end,
  count(*)                      AS n,
  sum(c.amount)                 AS total_amount
FROM public.cash_register_preliminary c
JOIN public.accounts ra ON (ra.account_number_last4 = c.account_last4 OR c.account_last4 = ANY(ra.alternate_last4s))
JOIN public.statement_balances sb ON sb.agency_id = c.agency_id
  AND (sb.account_last4 = ra.account_number_last4 OR sb.account_last4 = ANY(COALESCE(ra.alternate_last4s, ARRAY[]::text[])))
  AND c.txn_date BETWEEN sb.statement_period_start AND sb.statement_period_end
WHERE c.status = 'possible_transfer'
  AND NOT EXISTS (
    SELECT 1 FROM public.statements s
    WHERE s.agency_id = c.agency_id AND s.account_id = ra.id
      AND round(abs(s.amount),2) = round(c.amount,2)
      AND (CASE WHEN s.transaction_type IN ('withdrawal','charge','debit') THEN 'debit'
                WHEN s.transaction_type IN ('deposit','payment_or_credit','credit','payment') THEN 'credit'
                ELSE NULL END) = c.direction
      AND abs(s.transaction_date - c.txn_date) <= 4
  )
GROUP BY c.agency_id, ra.id, ra.account_name, sb.id, sb.statement_period_start, sb.statement_period_end;

GRANT SELECT ON public.v_dormant_gl_rules TO authenticated, service_role;
GRANT SELECT ON public.v_not_on_statement TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.ensure_watcher_task(
  p_agency_id   uuid,
  p_category    text,
  p_related_id  uuid,
  p_title       text,
  p_description text,
  p_priority    text DEFAULT 'medium'
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_owner uuid := '67f7287d-7110-405f-a7bd-4db433e6d17f';
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.tasks t
    WHERE t.agency_id = p_agency_id
      AND t.task_category = p_category
      AND t.related_id IS NOT DISTINCT FROM p_related_id
      AND t.status = 'open'
  ) THEN
    RETURN false;
  END IF;

  INSERT INTO public.tasks
    (agency_id, title, description, assigned_to, created_by, priority, status,
     related_id, task_category, task_type, backlog_state)
  VALUES
    (p_agency_id, p_title, p_description, v_owner, 'newtworks_watcher', p_priority, 'open',
     p_related_id, p_category, 'task', 'active');

  RETURN true;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.close_watcher_task(
  p_agency_id  uuid,
  p_category   text,
  p_related_id uuid
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_closed integer := 0;
BEGIN
  WITH done AS (
    UPDATE public.tasks t
    SET status = 'completed', completed_at = now(), updated_at = now()
    WHERE t.agency_id = p_agency_id
      AND t.task_category = p_category
      AND t.related_id IS NOT DISTINCT FROM p_related_id
      AND t.status = 'open'
    RETURNING 1
  )
  SELECT count(*) INTO v_closed FROM done;
  RETURN v_closed;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.ensure_watcher_task(uuid,text,uuid,text,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.close_watcher_task(uuid,text,uuid) TO service_role;
