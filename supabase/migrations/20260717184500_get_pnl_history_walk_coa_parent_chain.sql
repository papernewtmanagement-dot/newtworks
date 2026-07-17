-- Replace get_pnl_history's stupid "Z Post-6/30 ledger" bucket with a COA parent walk.
-- Every post-cutover account already has a parent_account_id chain that terminates
-- at an envelope root (4005 State Farm, 0001 ADMINISTRATION, 0002 TEAM, etc.),
-- which is the SAME vocabulary prior_year_pl.section uses. So both halves of the
-- P&L render under the same section labels — no artificial cutover bucket.

CREATE OR REPLACE FUNCTION public.get_pnl_history()
RETURNS json
LANGUAGE sql
STABLE
AS $function$
  WITH RECURSIVE ancestry AS (
    -- Base: every account is its own starting leaf
    SELECT id AS leaf_id, id AS cur_id, account_name, parent_account_id
    FROM public.chart_of_accounts
    UNION ALL
    -- Walk up
    SELECT a.leaf_id, p.id, p.account_name, p.parent_account_id
    FROM public.chart_of_accounts p
    JOIN ancestry a ON a.parent_account_id = p.id
  ),
  coa_root AS (
    -- For each leaf, keep only the row where parent_account_id IS NULL (the root)
    SELECT leaf_id, account_name AS root_name
    FROM ancestry
    WHERE parent_account_id IS NULL
  ),
  src AS (
    -- Post-cutover: journal_entries rows (identified by non-NULL account_id in the view)
    -- get their section by walking COA parent chain to root.
    SELECT
      v.year::int  AS year,
      v.month::int AS month,
      v.account_name,
      v.account_type::text AS account_type,
      COALESCE(r.root_name, 'Uncategorized') AS section,
      v.amount
    FROM public.v_income_statement v
    LEFT JOIN coa_root r ON r.leaf_id = v.account_id
    WHERE v.account_id IS NOT NULL

    UNION ALL

    -- Pre-cutover: prior_year_pl rows already carry the section label in account_subtype.
    -- (v_income_statement maps prior_year_pl.section -> account_subtype for uniformity.)
    SELECT
      v.year::int,
      v.month::int,
      v.account_name,
      v.account_type::text,
      COALESCE(v.account_subtype, 'Uncategorized') AS section,
      v.amount
    FROM public.v_income_statement v
    WHERE v.account_id IS NULL
  )
  SELECT COALESCE(json_agg(t ORDER BY t.year, t.month, t.account_type, t.section, t.account_name), '[]'::json)
  FROM (
    SELECT year, month, account_name, account_type, section, SUM(amount)::numeric AS amount
    FROM src
    GROUP BY year, month, account_name, account_type, section
  ) t;
$function$;
