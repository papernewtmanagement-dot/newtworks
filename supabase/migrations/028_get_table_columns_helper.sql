-- Helper used by automation-runner to discover which fields on a parsed LLM record
-- are real columns on the output table (vs LLM metadata like source_message_id,
-- quarter_year, lead_sources, etc.). Stripping unknown fields before insert lets
-- the runner support recipes whose LLM response carries extra context fields that
-- don't belong on the primary table (e.g., book_snapshot recipe with lead_sources
-- arrays that belong on lead_source_quarterly instead).
CREATE OR REPLACE FUNCTION public.get_table_columns_v1(p_table_name text)
RETURNS TABLE (column_name text)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
  SELECT c.column_name::text
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = p_table_name
$$;

GRANT EXECUTE ON FUNCTION public.get_table_columns_v1(text) TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.get_table_columns_v1 IS
  'Returns the list of column names for a public-schema table. Used by automation-runner to filter parsed LLM records to known columns before insert.';
