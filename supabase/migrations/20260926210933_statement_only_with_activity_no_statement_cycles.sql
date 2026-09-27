-- Cards that issue no statement in a cycle with no activity (AMEX Personal:
-- Marie confirmed 2026-08-18 that AMEX posted none) were being reported missing
-- every month. New account setting statement_only_with_activity: such an account
-- is only missing a statement when it carried a balance or showed activity in
-- the period. statement_issues() re-created with that one rule added.
ALTER TABLE public.accounts
  ADD COLUMN IF NOT EXISTS statement_only_with_activity boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.accounts.statement_only_with_activity IS
  'True when the issuer sends no statement for a cycle with no activity and a zero balance (AMEX Personal). Such a cycle is then not reported missing.';
UPDATE public.accounts SET statement_only_with_activity = true
 WHERE id = '50ba6422-c1a6-4e2b-bd5e-5c757fa86332';

CREATE OR REPLACE FUNCTION public.statement_issues(p_agency_id uuid)
RETURNS TABLE (
  agency_id uuid, account_id uuid, account_code text, account_name text, institution text,
  last4 text, business_entity_id uuid, account_kind text, issue text,
  period_start date, period_end date, due_date date, document_id uuid, file_name text, detail text
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
WITH acct AS (
  SELECT a.id AS account_id, a.agency_id, a.business_entity_id, a.account_name, a.institution,
         a.account_number_last4 AS last4, a.account_kind, a.statement_close_day AS close_day,
         a.statement_ready_days AS ready_days, a.statement_only_with_activity AS only_with_activity,
         a.alternate_last4s, coa.account_code
    FROM accounts a
    JOIN chart_of_accounts coa ON coa.id = a.chart_account_id
   WHERE a.agency_id = p_agency_id AND a.is_active AND a.statement_covered_by_account_id IS NULL
     -- Signed-in callers see only their own agency, and never a family login.
     -- Scheduled jobs run with no signed-in user and see the agency they name.
     AND (auth.uid() IS NULL OR EXISTS (SELECT 1 FROM users u
                                         WHERE u.auth_user_id = auth.uid() AND u.agency_id = p_agency_id
                                           AND u.role <> 'family'))
),
sb AS (
  SELECT s.account_code, s.statement_period_start AS ps, s.statement_period_end AS pe,
         s.opening_balance AS ob, s.closing_balance AS cb,
         lag(s.statement_period_end) OVER w AS prev_pe,
         lag(s.closing_balance) OVER w AS prev_cb
    FROM statement_balances s
   WHERE s.agency_id = p_agency_id
  WINDOW w AS (PARTITION BY s.account_code ORDER BY s.statement_period_end)
),
pending_docs AS (
  SELECT d.source_account_code AS account_code, d.id AS document_id, d.file_name,
         d.processing_status, d.created_at
    FROM documents d
   WHERE d.agency_id = p_agency_id
     AND d.source_account_code IS NOT NULL
     AND d.processing_status IN ('queued_for_llm', 'error', 'held_reconciliation_mismatch')
     AND d.created_at > now() - interval '120 days'
     AND NOT EXISTS (SELECT 1 FROM statement_balances s2 WHERE s2.source_document_id = d.id)
),
gaps AS (
  SELECT a.*, (sb.prev_pe + 1) AS p_start, (sb.ps - 1) AS p_end
    FROM acct a JOIN sb ON sb.account_code = a.account_code
   WHERE sb.prev_pe IS NOT NULL AND sb.ps IS NOT NULL AND sb.ps - sb.prev_pe > 5
     AND round(sb.prev_cb, 2) IS DISTINCT FROM round(sb.ob, 2)
),
latest AS (
  SELECT DISTINCT ON (account_code) account_code, pe AS last_pe, cb AS last_cb
    FROM sb ORDER BY account_code, pe DESC
),
expected AS (
  SELECT a.*, l.last_cb, e.close_date,
         COALESCE(lag(e.close_date) OVER (PARTITION BY a.account_id ORDER BY e.close_date), l.last_pe) + 1 AS p_start
    FROM acct a
    JOIN latest l ON l.account_code = a.account_code
    CROSS JOIN LATERAL (
      SELECT (m + (LEAST(a.close_day, extract(day FROM (m + interval '1 month' - interval '1 day'))::int) - 1)
                  * interval '1 day')::date AS close_date
        FROM generate_series(date_trunc('month', l.last_pe) + interval '1 month',
                             date_trunc('month', current_date), interval '1 month') AS m
    ) e
   WHERE a.close_day IS NOT NULL
)
SELECT g.agency_id, g.account_id, g.account_code, g.account_name, g.institution, g.last4,
       g.business_entity_id, g.account_kind, 'missing'::text,
       g.p_start, g.p_end, statement_due_date(g.p_end, g.ready_days), NULL::uuid, NULL::text,
       format('Statement for %s – %s is missing', to_char(g.p_start, 'Mon FMDD'), to_char(g.p_end, 'Mon FMDD'))
  FROM gaps g
UNION ALL
SELECT x.agency_id, x.account_id, x.account_code, x.account_name, x.institution, x.last4,
       x.business_entity_id, x.account_kind, 'missing'::text,
       x.p_start, x.close_date, statement_due_date(x.close_date, x.ready_days), NULL::uuid, NULL::text,
       format('Statement for %s – %s hasn''t come in (due %s)', to_char(x.p_start, 'Mon FMDD'),
              to_char(x.close_date, 'Mon FMDD'), to_char(statement_due_date(x.close_date, x.ready_days), 'Mon FMDD'))
  FROM expected x
 WHERE statement_due_date(x.close_date, x.ready_days) < current_date
   AND NOT EXISTS (SELECT 1 FROM pending_docs p
                    WHERE p.account_code = x.account_code AND p.created_at::date >= x.close_date)
   -- Cards that issue no statement for a cycle with no activity (AMEX Personal,
   -- Marie 2026-08-18): only missing when there is a balance or activity to report.
   AND (NOT x.only_with_activity
        OR round(COALESCE(x.last_cb, 0), 2) <> 0
        OR EXISTS (SELECT 1 FROM cash_register_preliminary c
                    WHERE c.agency_id = x.agency_id
                      AND (c.account_last4 = x.last4 OR c.account_last4 = ANY (x.alternate_last4s))
                      AND c.txn_date BETWEEN x.p_start AND x.close_date))
UNION ALL
SELECT a.agency_id, a.account_id, a.account_code, a.account_name, a.institution, a.last4,
       a.business_entity_id, a.account_kind,
       CASE WHEN p.processing_status = 'queued_for_llm' THEN 'waiting' ELSE 'unread' END,
       NULL::date, NULL::date, NULL::date, p.document_id, p.file_name,
       CASE WHEN p.processing_status = 'queued_for_llm'
            THEN format('%s is waiting to be read', p.file_name)
            ELSE format('%s couldn''t be read yet', p.file_name) END
  FROM pending_docs p JOIN acct a ON a.account_code = p.account_code
$$;
