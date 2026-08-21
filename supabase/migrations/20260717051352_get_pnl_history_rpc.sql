-- ================================================================
-- get_pnl_history() RPC — returns full P&L history as ONE JSON blob.
--
-- Why: Supabase PostgREST enforces a project-level max_rows cap
-- (default 1000 for this project). Even with .limit(50000) in the JS
-- client, PostgREST truncated my v_income_statement queries at 1000
-- rows, silently dropping years 2024/2025 from the annual grain.
--
-- Returning json_agg wraps the whole result set into a single row,
-- bypassing the row cap entirely. Aggregated at
-- (year, month, account_name, account_type) so downstream FE math
-- stays unchanged.
--
-- SECURITY INVOKER so RLS on underlying tables (prior_year_pl,
-- journal_entries) still applies to the caller's role.
-- ================================================================
CREATE OR REPLACE FUNCTION public.get_pnl_history()
RETURNS json
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
  SELECT COALESCE(json_agg(t ORDER BY t.year, t.month, t.account_type, t.account_name), '[]'::json)
  FROM (
    SELECT
      year::int          AS year,
      month::int         AS month,
      account_name       AS account_name,
      account_type::text AS account_type,
      SUM(amount)::numeric AS amount
    FROM public.v_income_statement
    GROUP BY year, month, account_name, account_type
  ) t;
$$;

GRANT EXECUTE ON FUNCTION public.get_pnl_history() TO authenticated, anon;
