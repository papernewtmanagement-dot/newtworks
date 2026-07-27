-- Kill last remnant of cutover: v_balance_sheet_anchored's dependency on gl_anchor_date setting.
-- Hardcode 6/30/2026 as the balance sheet snapshot as-of date. Delete the setting.

CREATE OR REPLACE VIEW public.v_balance_sheet_anchored AS
WITH agency AS (
  SELECT '126794dd-25ff-47d2-a436-724499733365'::uuid AS id
), cfg AS (
  SELECT '2026-06-30'::date AS anchor_date
), post_activity AS (
  SELECT coa.account_code,
    max(coa.account_name) AS account_name,
    coa.account_type,
    je.business_entity_id,
    round(sum(CASE
      WHEN coa.account_type = ANY (ARRAY['asset'::text, 'expense'::text]) THEN jl.debit - jl.credit
      ELSE jl.credit - jl.debit
    END), 2) AS activity
  FROM journal_entries je
    JOIN journal_lines jl ON jl.journal_entry_id = je.id
    JOIN chart_of_accounts coa ON coa.id = jl.account_id
    CROSS JOIN agency
    CROSS JOIN cfg
  WHERE je.agency_id = agency.id
    AND je.entry_date > cfg.anchor_date
    AND (coa.account_type = ANY (ARRAY['asset'::text, 'liability'::text, 'equity'::text]))
  GROUP BY coa.account_code, coa.account_type, je.business_entity_id
), post_net_income AS (
  SELECT je.business_entity_id,
    round(sum(CASE
      WHEN coa.account_type = 'income'::text THEN jl.credit - jl.debit
      WHEN coa.account_type = 'expense'::text THEN -(jl.debit - jl.credit)
      ELSE 0::numeric
    END), 2) AS ni
  FROM journal_entries je
    JOIN journal_lines jl ON jl.journal_entry_id = je.id
    JOIN chart_of_accounts coa ON coa.id = jl.account_id
    CROSS JOIN agency
    CROSS JOIN cfg
  WHERE je.agency_id = agency.id
    AND je.entry_date > cfg.anchor_date
    AND (coa.account_type = ANY (ARRAY['income'::text, 'expense'::text]))
  GROUP BY je.business_entity_id
), codes AS (
  SELECT ob.account_code, ob.business_entity_id
  FROM opening_balances ob CROSS JOIN agency CROSS JOIN cfg
  WHERE ob.agency_id = agency.id AND ob.as_of_date = cfg.anchor_date
  UNION
  SELECT pa.account_code, pa.business_entity_id FROM post_activity pa
)
SELECT agency.id AS agency_id,
  c.account_code,
  COALESCE(ob.account_name, pa.account_name) AS account_name,
  COALESCE(ob.account_type, pa.account_type) AS account_type,
  COALESCE(ob.opening_balance, 0::numeric) AS opening_balance,
  COALESCE(pa.activity, 0::numeric) AS activity_since_open,
  round(COALESCE(ob.opening_balance, 0::numeric) + COALESCE(pa.activity, 0::numeric), 2) AS balance_current,
  c.business_entity_id
FROM codes c CROSS JOIN agency CROSS JOIN cfg
LEFT JOIN opening_balances ob ON ob.account_code = c.account_code
  AND ob.business_entity_id = c.business_entity_id
  AND ob.agency_id = agency.id
  AND ob.as_of_date = cfg.anchor_date
LEFT JOIN post_activity pa ON pa.account_code = c.account_code
  AND pa.business_entity_id = c.business_entity_id
UNION ALL
SELECT agency.id AS agency_id,
  'NI-POST-OPEN'::text AS account_code,
  'Net Income (post-anchor)'::text AS account_name,
  'equity'::text AS account_type,
  0::numeric AS opening_balance,
  pni.ni AS activity_since_open,
  pni.ni AS balance_current,
  pni.business_entity_id
FROM post_net_income pni CROSS JOIN agency;

DELETE FROM public.settings
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  AND setting_key = 'gl_anchor_date';
