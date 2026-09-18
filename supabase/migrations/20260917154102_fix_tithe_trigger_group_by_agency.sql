-- Fix: min() has no uuid version, so the trigger errored on every ledger write.
-- Now groups the changed rows by agency and reconciles each one.

CREATE OR REPLACE FUNCTION public.tg_ledger_tithe_pool_accrue()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.agency_id, array_agg(c.id) AS ids
    FROM changed_rows c
    WHERE c.agency_id IS NOT NULL
    GROUP BY c.agency_id
  LOOP
    -- no percentages set for this agency means nothing to do
    IF EXISTS (SELECT 1 FROM tithe_pool_rules t WHERE t.agency_id = r.agency_id AND t.is_active) THEN
      PERFORM tithe_pool_reconcile(r.agency_id, r.ids);
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;
