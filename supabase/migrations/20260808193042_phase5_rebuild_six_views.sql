-- ================================================================
-- 5a-1: v_income_statement (anchor 20260717033459), remapped to ledger.
-- Ledger side filtered to entry_date >= 2026-01-01. prior_year_pl unfiltered.
-- ================================================================
CREATE OR REPLACE VIEW public.v_income_statement AS
SELECT
  l.agency_id,
  EXTRACT(year  FROM l.entry_date)::integer                       AS period_year,
  EXTRACT(month FROM l.entry_date)::integer                       AS period_month,
  EXTRACT(year  FROM l.entry_date)::integer                       AS year,
  EXTRACT(month FROM l.entry_date)::integer                       AS month,
  to_char(l.entry_date::timestamp with time zone, 'YYYY-MM'::text) AS period,
  date_trunc('month', l.entry_date::timestamp with time zone)::date AS period_date,
  coa.id                                                          AS account_id,
  coa.account_code,
  coa.account_name,
  coa.account_type,
  coa.account_subtype,
  sum(l.debit)                                                    AS total_debit,
  sum(l.credit)                                                   AS total_credit,
  CASE
    WHEN coa.account_type = 'income'  AND l.source LIKE 'historical_import%' THEN sum(l.debit)  - sum(l.credit)
    WHEN coa.account_type = 'income'                                          THEN sum(l.credit) - sum(l.debit)
    WHEN coa.account_type = 'expense'                                         THEN sum(l.debit)  - sum(l.credit)
    ELSE 0::numeric
  END                                                             AS amount
FROM ledger l
JOIN chart_of_accounts coa ON coa.id = l.account_id
WHERE coa.account_type IN ('income', 'expense')
  AND l.entry_date >= '2026-01-01'
GROUP BY l.agency_id, l.entry_date, l.source,
         coa.id, coa.account_code, coa.account_name,
         coa.account_type, coa.account_subtype

UNION ALL

SELECT
  py.agency_id,
  py.period_year                                                  AS period_year,
  py.period_month                                                 AS period_month,
  py.period_year                                                  AS year,
  py.period_month                                                 AS month,
  to_char(py.period_start::timestamp with time zone, 'YYYY-MM'::text) AS period,
  date_trunc('month', py.period_start::timestamp with time zone)::date AS period_date,
  NULL::uuid                                                      AS account_id,
  NULL::text                                                      AS account_code,
  py.account_name,
  LOWER(py.section_type)                                          AS account_type,
  py.section                                                      AS account_subtype,
  NULL::numeric                                                   AS total_debit,
  NULL::numeric                                                   AS total_credit,
  py.amount
FROM prior_year_pl py
WHERE LOWER(py.section_type) IN ('income', 'expense');

-- ================================================================
-- 5a-2: v_statement_reconciliation (anchor 20260807020702), remapped to ledger.
-- CTE renamed ledger_agg to avoid colliding with the actual ledger table.
-- ================================================================
CREATE OR REPLACE VIEW public.v_statement_reconciliation AS
WITH resolved AS (
  SELECT
    sb.id AS statement_balance_id,
    sb.account_code,
    sb.account_kind,
    sb.business_entity_id,
    sb.statement_period_end,
    sb.closing_balance,
    coa.id AS coa_id,
    coa.account_name AS coa_account_name,
    COUNT(*) OVER (PARTITION BY sb.id) AS coa_match_count
  FROM public.statement_balances sb
  LEFT JOIN public.chart_of_accounts coa
    ON coa.account_code = sb.account_code
    AND (
      (sb.business_entity_id IS NOT NULL AND coa.business_entity_id = sb.business_entity_id)
      OR (sb.business_entity_id IS NULL)
    )
  WHERE sb.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND sb.statement_period_end IS NOT NULL
    AND sb.account_kind IN ('bank','credit')
),
dedup AS (
  SELECT DISTINCT ON (statement_balance_id)
    statement_balance_id,
    account_code,
    account_kind,
    business_entity_id,
    statement_period_end,
    closing_balance,
    coa_id,
    coa_account_name,
    (coa_match_count > 1) AS coa_match_ambiguous
  FROM resolved
  ORDER BY statement_balance_id, coa_id NULLS LAST
),
ledger_agg AS (
  SELECT
    d.statement_balance_id,
    CASE
      WHEN d.account_kind = 'bank' THEN COALESCE(SUM(l.debit), 0) - COALESCE(SUM(l.credit), 0)
      WHEN d.account_kind = 'credit' THEN COALESCE(SUM(l.credit), 0) - COALESCE(SUM(l.debit), 0)
    END AS ledger_balance
  FROM dedup d
  LEFT JOIN public.ledger l
    ON l.account_id = d.coa_id
    AND l.entry_date <= d.statement_period_end
  WHERE d.coa_id IS NOT NULL
  GROUP BY d.statement_balance_id, d.account_kind
),
base AS (
  SELECT
    d.statement_balance_id,
    d.account_code,
    d.coa_account_name AS account_name,
    d.account_kind,
    d.business_entity_id,
    d.statement_period_end,
    d.closing_balance,
    COALESCE(la.ledger_balance, 0) AS ledger_balance,
    d.coa_match_ambiguous
  FROM dedup d
  LEFT JOIN ledger_agg la ON la.statement_balance_id = d.statement_balance_id
),
with_variance AS (
  SELECT *, (ledger_balance - closing_balance) AS variance
  FROM base
),
with_prior AS (
  SELECT
    *,
    LAG(variance) OVER (
      PARTITION BY account_code, business_entity_id
      ORDER BY statement_period_end
    ) AS prior_variance
  FROM with_variance
)
SELECT
  statement_balance_id,
  account_code,
  account_name,
  account_kind,
  business_entity_id,
  statement_period_end,
  closing_balance,
  ledger_balance,
  variance,
  prior_variance,
  CASE WHEN prior_variance IS NULL THEN NULL ELSE (variance - prior_variance) END AS variance_delta,
  coa_match_ambiguous,
  CASE
    WHEN coa_match_ambiguous THEN 'ambiguous_account'
    WHEN ABS(variance) <= 0.01 THEN 'ties'
    WHEN prior_variance IS NOT NULL AND ABS(variance - prior_variance) > 0.01 THEN 'in_period_error'
    ELSE 'baseline_offset'
  END AS finding
FROM with_prior;

-- ================================================================
-- 5a-3: v_growth_budget_licensing_ytd (anchor 20260727213911), remapped to ledger.
-- ================================================================
CREATE OR REPLACE VIEW public.v_growth_budget_licensing_ytd AS
SELECT l.agency_id,
    a.account_code,
    a.account_name,
    (date_trunc('year'::text, COALESCE((l.entry_date)::timestamp with time zone, l.created_at)))::date AS year_start,
    round(sum((COALESCE(l.debit, (0)::numeric) - COALESCE(l.credit, (0)::numeric))), 2) AS licensing_ytd_dollars,
    count(*) AS entry_count,
    jsonb_agg(jsonb_build_object('journal_entry_id', l.id, 'entry_date', l.entry_date, 'debit', l.debit, 'credit', l.credit, 'description', l.description) ORDER BY l.entry_date DESC) AS entries
   FROM (ledger l
     JOIN chart_of_accounts a ON ((a.id = l.account_id)))
  WHERE ((a.account_code = '6715'::text) AND (date_trunc('year'::text, COALESCE((l.entry_date)::timestamp with time zone, l.created_at)) = date_trunc('year'::text, (CURRENT_DATE)::timestamp with time zone)))
  GROUP BY l.agency_id, a.account_code, a.account_name, (date_trunc('year'::text, COALESCE((l.entry_date)::timestamp with time zone, l.created_at)));

-- ================================================================
-- 5a-4: v_growth_budget_full_ytd (anchor 20260806214506), verbatim —
-- does not touch journal_entries/journal_lines directly, only nested views.
-- ================================================================
CREATE OR REPLACE VIEW public.v_growth_budget_full_ytd AS
 WITH salary_totals AS (
         SELECT v_growth_budget_ytd.agency_id,
            round(sum(v_growth_budget_ytd.growth_budget_ytd), 2) AS salary_ramp_ytd_dollars,
            sum(v_growth_budget_ytd.weeks_ramping_ytd) AS total_weeks_ramping_ytd,
            count(*) AS active_new_hires_ramping
           FROM v_growth_budget_ytd
          GROUP BY v_growth_budget_ytd.agency_id
        ), licensing_totals AS (
         SELECT v_growth_budget_licensing_ytd.agency_id,
            v_growth_budget_licensing_ytd.licensing_ytd_dollars,
            v_growth_budget_licensing_ytd.entry_count AS licensing_entries_ytd
           FROM v_growth_budget_licensing_ytd
        )
 SELECT COALESCE(s.agency_id, l.agency_id) AS agency_id,
    COALESCE(s.salary_ramp_ytd_dollars, 0::numeric) AS salary_ramp_ytd_dollars,
    COALESCE(l.licensing_ytd_dollars, 0::numeric) AS licensing_ytd_dollars,
    COALESCE(s.salary_ramp_ytd_dollars, 0::numeric) + COALESCE(l.licensing_ytd_dollars, 0::numeric) AS total_growth_budget_ytd_dollars,
    COALESCE(s.active_new_hires_ramping, 0::bigint) AS active_new_hires_ramping,
    COALESCE(s.total_weeks_ramping_ytd, 0::numeric) AS total_weeks_ramping_ytd,
    COALESCE(l.licensing_entries_ytd, 0::bigint) AS licensing_entries_ytd
   FROM salary_totals s
     FULL JOIN licensing_totals l ON l.agency_id = s.agency_id
  WHERE public.is_agency_admin();

-- ================================================================
-- 5b-1: v_bank_balances — fresh build. Balances from statement_balances ONLY.
-- ================================================================
CREATE OR REPLACE VIEW public.v_bank_balances AS
WITH latest_stmt AS (
  SELECT DISTINCT ON (account_code)
    account_code, statement_period_end, opening_balance, closing_balance
  FROM public.statement_balances
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND account_kind = 'bank'
  ORDER BY account_code, statement_period_end DESC
)
SELECT
  a.agency_id,
  a.business_entity_id,
  a.id AS account_id,
  a.account_name,
  a.institution,
  a.account_number_last4,
  a.alternate_last4s,
  coa.account_code,
  a.account_kind,
  a.statement_close_day,
  a.is_active,
  ls.statement_period_end AS last_statement_period_end,
  ls.opening_balance AS last_statement_opening_balance,
  ls.closing_balance AS current_balance_derived,
  exp.expected_last_close,
  (CURRENT_DATE - ls.statement_period_end) AS days_since_close,
  (exp.expected_last_close IS NOT NULL AND
   (ls.statement_period_end IS NULL OR ls.statement_period_end < exp.expected_last_close)) AS is_overdue,
  a.chart_account_id,
  a.account_type,
  (ls.closing_balance < 0) AS needs_review
FROM public.accounts a
LEFT JOIN public.chart_of_accounts coa ON coa.id = a.chart_account_id
LEFT JOIN latest_stmt ls ON ls.account_code = coa.account_code
LEFT JOIN LATERAL (
  SELECT (mc.close_date) AS expected_last_close
  FROM (
    SELECT (month_start + (LEAST(a.statement_close_day, EXTRACT(day FROM (month_start + interval '1 month - 1 day'))::int) - 1) * interval '1 day')::date AS close_date
    FROM generate_series(date_trunc('month', CURRENT_DATE) - interval '1 month', date_trunc('month', CURRENT_DATE), interval '1 month') AS month_start
  ) mc
  WHERE a.statement_close_day IS NOT NULL AND mc.close_date <= CURRENT_DATE
  ORDER BY mc.close_date DESC
  LIMIT 1
) exp ON true
WHERE a.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND a.account_kind = 'bank'
ORDER BY a.account_name;

-- ================================================================
-- 5b-2: v_card_balances — fresh build. Balances from statement_balances ONLY.
-- ================================================================
CREATE OR REPLACE VIEW public.v_card_balances AS
WITH latest_stmt AS (
  SELECT DISTINCT ON (account_code)
    account_code, statement_period_end, opening_balance, closing_balance
  FROM public.statement_balances
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND account_kind = 'credit'
  ORDER BY account_code, statement_period_end DESC
)
SELECT
  a.agency_id,
  a.business_entity_id,
  a.id AS account_id,
  a.account_name,
  a.institution,
  a.account_number_last4,
  a.alternate_last4s,
  coa.account_code,
  a.account_kind,
  a.statement_close_day,
  a.is_active,
  ls.statement_period_end AS last_statement_period_end,
  ls.opening_balance AS last_statement_opening_balance,
  ls.closing_balance AS current_balance_derived,
  exp.expected_last_close,
  (CURRENT_DATE - ls.statement_period_end) AS days_since_close,
  (exp.expected_last_close IS NOT NULL AND
   (ls.statement_period_end IS NULL OR ls.statement_period_end < exp.expected_last_close)) AS is_overdue,
  a.credit_limit,
  a.minimum_payment,
  a.payment_due_day,
  (a.credit_limit - ls.closing_balance) AS available_credit,
  a.chart_account_id,
  a.account_type,
  a.interest_rate,
  (a.account_number_last4 IS NULL) AS needs_last4,
  (ls.closing_balance < 0) AS needs_review
FROM public.accounts a
LEFT JOIN public.chart_of_accounts coa ON coa.id = a.chart_account_id
LEFT JOIN latest_stmt ls ON ls.account_code = coa.account_code
LEFT JOIN LATERAL (
  SELECT (mc.close_date) AS expected_last_close
  FROM (
    SELECT (month_start + (LEAST(a.statement_close_day, EXTRACT(day FROM (month_start + interval '1 month - 1 day'))::int) - 1) * interval '1 day')::date AS close_date
    FROM generate_series(date_trunc('month', CURRENT_DATE) - interval '1 month', date_trunc('month', CURRENT_DATE), interval '1 month') AS month_start
  ) mc
  WHERE a.statement_close_day IS NOT NULL AND mc.close_date <= CURRENT_DATE
  ORDER BY mc.close_date DESC
  LIMIT 1
) exp ON true
WHERE a.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND a.account_kind = 'credit'
ORDER BY a.account_name;

-- ================================================================
-- 5c: security_invoker + grants on all six
-- ================================================================
ALTER VIEW public.v_income_statement SET (security_invoker = true);
ALTER VIEW public.v_statement_reconciliation SET (security_invoker = true);
ALTER VIEW public.v_growth_budget_licensing_ytd SET (security_invoker = true);
ALTER VIEW public.v_growth_budget_full_ytd SET (security_invoker = true);
ALTER VIEW public.v_bank_balances SET (security_invoker = true);
ALTER VIEW public.v_card_balances SET (security_invoker = true);

REVOKE ALL ON public.v_income_statement FROM anon, PUBLIC;
REVOKE ALL ON public.v_statement_reconciliation FROM anon, PUBLIC;
REVOKE ALL ON public.v_growth_budget_licensing_ytd FROM anon, PUBLIC;
REVOKE ALL ON public.v_growth_budget_full_ytd FROM anon, PUBLIC;
REVOKE ALL ON public.v_bank_balances FROM anon, PUBLIC;
REVOKE ALL ON public.v_card_balances FROM anon, PUBLIC;

GRANT SELECT ON public.v_income_statement TO authenticated;
GRANT SELECT ON public.v_statement_reconciliation TO authenticated;
GRANT SELECT ON public.v_growth_budget_licensing_ytd TO authenticated;
GRANT SELECT ON public.v_growth_budget_full_ytd TO authenticated;
GRANT SELECT ON public.v_bank_balances TO authenticated;
GRANT SELECT ON public.v_card_balances TO authenticated;
