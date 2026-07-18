-- Phase 5 (entity hierarchy): expose business_entity_id on v_balance_sheet_anchored
--
-- Adds business_entity_id as the LAST column so CREATE OR REPLACE VIEW succeeds
-- (PG 42P16 restriction: additive-only at end of SELECT — same rule as Phase 4).
-- Preserves all existing column names, types, and ordering.
--
-- Behavioral changes:
--   1. Each BS row now carries the entity that owns it (opening_balance side
--      from opening_balances.business_entity_id; post-anchor activity side from
--      journal_entries.business_entity_id). Rows with the SAME account_code but
--      DIFFERENT entities produce SEPARATE rows — Option B flat listing.
--   2. NI-POST-OPEN synthetic row is now emitted PER entity that has non-zero
--      post-anchor income/expense activity. Old behavior: always emitted one
--      row across the whole agency. If no post-anchor activity exists anywhere,
--      no NI-POST-OPEN row is emitted (was previously a single zero-value row).

CREATE OR REPLACE VIEW public.v_balance_sheet_anchored AS
WITH agency AS (
    SELECT '126794dd-25ff-47d2-a436-724499733365'::uuid AS id
),
cfg AS (
    SELECT (settings.setting_value)::date AS anchor_date
    FROM settings CROSS JOIN agency
    WHERE settings.agency_id = agency.id
      AND settings.setting_key = 'gl_anchor_date'
),
post_activity AS (
    SELECT
        coa.account_code,
        max(coa.account_name) AS account_name,
        coa.account_type,
        je.business_entity_id,
        round(sum(
            CASE
                WHEN coa.account_type = ANY (ARRAY['asset'::text, 'expense'::text])
                    THEN (jl.debit - jl.credit)
                ELSE (jl.credit - jl.debit)
            END
        ), 2) AS activity
    FROM journal_entries je
        JOIN journal_lines jl ON jl.journal_entry_id = je.id
        JOIN chart_of_accounts coa ON coa.id = jl.account_id
        CROSS JOIN agency
        CROSS JOIN cfg
    WHERE je.agency_id = agency.id
      AND je.entry_date > cfg.anchor_date
      AND coa.account_type = ANY (ARRAY['asset'::text, 'liability'::text, 'equity'::text])
    GROUP BY coa.account_code, coa.account_type, je.business_entity_id
),
post_net_income AS (
    SELECT
        je.business_entity_id,
        round(sum(
            CASE
                WHEN coa.account_type = 'income'::text THEN (jl.credit - jl.debit)
                WHEN coa.account_type = 'expense'::text THEN -(jl.debit - jl.credit)
                ELSE 0::numeric
            END
        ), 2) AS ni
    FROM journal_entries je
        JOIN journal_lines jl ON jl.journal_entry_id = je.id
        JOIN chart_of_accounts coa ON coa.id = jl.account_id
        CROSS JOIN agency
        CROSS JOIN cfg
    WHERE je.agency_id = agency.id
      AND je.entry_date > cfg.anchor_date
      AND coa.account_type = ANY (ARRAY['income'::text, 'expense'::text])
    GROUP BY je.business_entity_id
),
codes AS (
    SELECT ob.account_code, ob.business_entity_id
    FROM opening_balances ob
        CROSS JOIN agency
        CROSS JOIN cfg
    WHERE ob.agency_id = agency.id
      AND ob.as_of_date = cfg.anchor_date
    UNION
    SELECT pa.account_code, pa.business_entity_id
    FROM post_activity pa
)
SELECT
    agency.id AS agency_id,
    c.account_code,
    COALESCE(ob.account_name, pa.account_name) AS account_name,
    COALESCE(ob.account_type, pa.account_type) AS account_type,
    COALESCE(ob.opening_balance, 0::numeric) AS opening_balance,
    COALESCE(pa.activity, 0::numeric) AS activity_since_open,
    round((COALESCE(ob.opening_balance, 0::numeric) + COALESCE(pa.activity, 0::numeric)), 2) AS balance_current,
    c.business_entity_id
FROM codes c
    CROSS JOIN agency
    CROSS JOIN cfg
    LEFT JOIN opening_balances ob
        ON ob.account_code = c.account_code
       AND ob.business_entity_id = c.business_entity_id
       AND ob.agency_id = agency.id
       AND ob.as_of_date = cfg.anchor_date
    LEFT JOIN post_activity pa
        ON pa.account_code = c.account_code
       AND pa.business_entity_id = c.business_entity_id

UNION ALL

SELECT
    agency.id AS agency_id,
    'NI-POST-OPEN'::text AS account_code,
    'Net Income (post-anchor)'::text AS account_name,
    'equity'::text AS account_type,
    0::numeric AS opening_balance,
    pni.ni AS activity_since_open,
    pni.ni AS balance_current,
    pni.business_entity_id
FROM post_net_income pni
    CROSS JOIN agency;

COMMENT ON VIEW public.v_balance_sheet_anchored IS
'Balance sheet at gl_anchor_date + activity through today. Per Phase 5 of the entity hierarchy work (2026-07-17), each row now carries business_entity_id — rows with the same account_code but different entities appear separately (Option B flat listing). NI-POST-OPEN is emitted per entity with non-zero post-anchor income/expense.';
