-- View refactor for 6/30/2026 anchor
-- Must DROP first because CREATE OR REPLACE VIEW can't rename columns.
-- No downstream views depend on the balance_anchor_0430/anchor_0430 column names (audited: only Financials.jsx reads these).

DROP VIEW IF EXISTS public.v_bank_balances CASCADE;
DROP VIEW IF EXISTS public.v_card_balances CASCADE;
DROP VIEW IF EXISTS public.v_balance_sheet_anchored CASCADE;
DROP VIEW IF EXISTS public.v_variance_historical_vs_active CASCADE;

CREATE VIEW public.v_bank_balances AS
WITH cfg AS (
  SELECT (setting_value::date) AS anchor_date
  FROM public.settings
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND setting_key='gl_anchor_date'
),
ledger AS (
  SELECT je.agency_id,
    coa.id AS chart_account_id,
    coa.account_code,
    coa.account_name,
    round(sum(jl.debit) - sum(jl.credit), 2) AS balance_total,
    round(sum(jl.debit) FILTER (WHERE je.entry_date <= cfg.anchor_date)
          - sum(jl.credit) FILTER (WHERE je.entry_date <= cfg.anchor_date), 2) AS balance_anchor,
    round(sum(jl.debit) FILTER (WHERE je.entry_date > cfg.anchor_date)
          - sum(jl.credit) FILTER (WHERE je.entry_date > cfg.anchor_date), 2) AS activity_since_anchor,
    max(je.entry_date) AS last_entry_date,
    count(DISTINCT je.id) AS entry_count
  FROM journal_entries je
  JOIN journal_lines jl ON jl.journal_entry_id = je.id
  JOIN chart_of_accounts coa ON coa.id = jl.account_id
  CROSS JOIN cfg
  WHERE coa.account_code = ANY (ARRAY['COA-001','COA-024','COA-002','COA-003','COA-004','COA-005','COA-006','COA-007'])
  GROUP BY je.agency_id, coa.id, coa.account_code, coa.account_name
)
SELECT agency_id, chart_account_id, account_code, account_name,
  COALESCE(balance_anchor, 0::numeric) AS balance_anchor,
  COALESCE(activity_since_anchor, 0::numeric) AS activity_since_anchor,
  COALESCE(balance_total, 0::numeric) AS current_balance_derived,
  last_entry_date, entry_count,
  (COALESCE(balance_total, 0::numeric) < 0::numeric) AS needs_review
FROM ledger;

CREATE VIEW public.v_card_balances AS
WITH cfg AS (
  SELECT (setting_value::date) AS anchor_date
  FROM public.settings
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND setting_key='gl_anchor_date'
),
ledger AS (
  SELECT je.agency_id,
    ca.id AS credit_account_id,
    ca.account_name,
    ca.institution,
    ca.chart_account_id,
    round(sum(jl.debit) - sum(jl.credit), 2) AS balance_total,
    round(sum(jl.debit) FILTER (WHERE je.entry_date <= cfg.anchor_date)
          - sum(jl.credit) FILTER (WHERE je.entry_date <= cfg.anchor_date), 2) AS balance_anchor,
    round(sum(jl.debit) FILTER (WHERE je.entry_date > cfg.anchor_date)
          - sum(jl.credit) FILTER (WHERE je.entry_date > cfg.anchor_date), 2) AS activity_since_anchor,
    max(je.entry_date) AS last_entry_date,
    count(DISTINCT je.id) AS entry_count
  FROM credit_accounts ca
  JOIN chart_of_accounts coa ON coa.id = ca.chart_account_id
  JOIN journal_lines jl ON jl.account_id = coa.id
  JOIN journal_entries je ON je.id = jl.journal_entry_id AND je.agency_id = ca.agency_id
  CROSS JOIN cfg
  GROUP BY je.agency_id, ca.id, ca.account_name, ca.institution, ca.chart_account_id
)
SELECT agency_id, credit_account_id, account_name, institution, chart_account_id,
  COALESCE(balance_anchor, 0::numeric) AS balance_anchor,
  COALESCE(activity_since_anchor, 0::numeric) AS activity_since_anchor,
  COALESCE(balance_total, 0::numeric) AS current_balance_derived,
  last_entry_date, entry_count,
  (COALESCE(balance_total, 0::numeric) < 0::numeric) AS needs_review
FROM ledger;

CREATE VIEW public.v_balance_sheet_anchored AS
WITH agency AS (
  SELECT '126794dd-25ff-47d2-a436-724499733365'::uuid AS id
),
cfg AS (
  SELECT (setting_value::date) AS anchor_date
  FROM public.settings
  CROSS JOIN agency
  WHERE agency_id = agency.id AND setting_key='gl_anchor_date'
),
post_activity AS (
  SELECT coa.account_code,
    max(coa.account_name) AS account_name,
    coa.account_type,
    round(sum(
      CASE WHEN coa.account_type IN ('asset','expense') THEN jl.debit - jl.credit
           ELSE jl.credit - jl.debit
      END), 2) AS activity
  FROM journal_entries je
  JOIN journal_lines jl ON jl.journal_entry_id = je.id
  JOIN chart_of_accounts coa ON coa.id = jl.account_id
  CROSS JOIN agency
  CROSS JOIN cfg
  WHERE je.agency_id = agency.id
    AND je.entry_date > cfg.anchor_date
    AND coa.account_type IN ('asset','liability','equity')
  GROUP BY coa.account_code, coa.account_type
),
post_net_income AS (
  SELECT round(sum(
      CASE WHEN coa.account_type = 'income' THEN jl.credit - jl.debit
           WHEN coa.account_type = 'expense' THEN -(jl.debit - jl.credit)
           ELSE 0::numeric
      END), 2) AS ni
  FROM journal_entries je
  JOIN journal_lines jl ON jl.journal_entry_id = je.id
  JOIN chart_of_accounts coa ON coa.id = jl.account_id
  CROSS JOIN agency
  CROSS JOIN cfg
  WHERE je.agency_id = agency.id
    AND je.entry_date > cfg.anchor_date
    AND coa.account_type IN ('income','expense')
),
codes AS (
  SELECT ob.account_code
    FROM opening_balances ob
    CROSS JOIN agency
    CROSS JOIN cfg
    WHERE ob.agency_id = agency.id AND ob.as_of_date = cfg.anchor_date
  UNION
  SELECT account_code FROM post_activity
)
SELECT agency.id AS agency_id,
  c.account_code,
  COALESCE(ob.account_name, pa.account_name) AS account_name,
  COALESCE(ob.account_type, pa.account_type) AS account_type,
  COALESCE(ob.opening_balance, 0::numeric) AS opening_balance,
  COALESCE(pa.activity, 0::numeric) AS activity_since_open,
  round(COALESCE(ob.opening_balance, 0::numeric) + COALESCE(pa.activity, 0::numeric), 2) AS balance_current
FROM codes c
CROSS JOIN agency
CROSS JOIN cfg
LEFT JOIN opening_balances ob ON ob.account_code = c.account_code
  AND ob.agency_id = agency.id
  AND ob.as_of_date = cfg.anchor_date
LEFT JOIN post_activity pa ON pa.account_code = c.account_code
UNION ALL
SELECT agency.id AS agency_id,
  'NI-POST-OPEN'::text AS account_code,
  'Net Income (post-anchor)'::text AS account_name,
  'equity'::text AS account_type,
  0::numeric AS opening_balance,
  COALESCE((SELECT ni FROM post_net_income), 0::numeric) AS activity_since_open,
  COALESCE((SELECT ni FROM post_net_income), 0::numeric) AS balance_current
FROM agency;

GRANT SELECT ON public.v_bank_balances TO anon, authenticated;
GRANT SELECT ON public.v_card_balances TO anon, authenticated;
GRANT SELECT ON public.v_balance_sheet_anchored TO anon, authenticated;
