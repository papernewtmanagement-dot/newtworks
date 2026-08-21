-- chatbot_read_sql: SECURITY DEFINER function called by the chatbot edge function's
-- read_sql tool. Hard guards: must be SELECT/WITH, runs in read-only transaction,
-- caps at 1000 rows. Returns jsonb array of row objects.
CREATE OR REPLACE FUNCTION public.chatbot_read_sql(p_query text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  result jsonb;
  cleaned text;
BEGIN
  -- Trim whitespace and trailing semicolons
  cleaned := regexp_replace(trim(p_query), ';\s*$', '');

  -- Guard 1: must start with SELECT or WITH (case-insensitive)
  IF cleaned !~* '^\s*(select|with)\s' THEN
    RAISE EXCEPTION 'chatbot_read_sql: only SELECT/WITH queries allowed';
  END IF;

  -- Guard 2: no embedded statement terminators (defense-in-depth vs injection)
  IF position(';' in cleaned) > 0 THEN
    RAISE EXCEPTION 'chatbot_read_sql: multi-statement queries not allowed';
  END IF;

  -- Guard 3: read-only transaction for this call
  SET LOCAL transaction_read_only = on;

  -- Execute, wrap in jsonb, cap at 1000 rows
  EXECUTE format(
    'SELECT coalesce(jsonb_agg(row_to_json(_outer)), ''[]''::jsonb)
     FROM (SELECT * FROM (%s) _inner LIMIT 1000) _outer',
    cleaned
  ) INTO result;

  RETURN result;
END;
$$;

REVOKE ALL ON FUNCTION public.chatbot_read_sql(text) FROM public;
GRANT EXECUTE ON FUNCTION public.chatbot_read_sql(text) TO service_role;

COMMENT ON FUNCTION public.chatbot_read_sql(text) IS
  'Read-only SQL execution gate for the chatbot edge function. Only SELECT/WITH, single-statement, capped at 1000 rows.';
