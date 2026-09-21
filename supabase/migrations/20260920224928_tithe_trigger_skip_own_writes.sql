-- pg_trigger_depth() did not catch the reconcile's own ledger writes when the
-- reconcile was called directly (depth is 1 there, not 2). The reconcile now
-- raises a transaction-local flag while it runs, and the trigger stands down
-- whenever the flag is up.

CREATE OR REPLACE FUNCTION public.tg_ledger_tithe_pool_accrue()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  r record;
BEGIN
  IF COALESCE(current_setting('newtworks.tithe_reconciling', true), '') = 'on' THEN
    RETURN NULL;
  END IF;
  FOR r IN
    SELECT c.agency_id, array_agg(c.id) AS ids
    FROM changed_rows c
    WHERE c.agency_id IS NOT NULL
    GROUP BY c.agency_id
  LOOP
    IF EXISTS (SELECT 1 FROM tithe_pool_rules t WHERE t.agency_id = r.agency_id AND t.is_active)
       OR EXISTS (SELECT 1 FROM tithe_draw_rules d WHERE d.agency_id = r.agency_id AND d.is_active) THEN
      PERFORM tithe_pool_reconcile(r.agency_id, r.ids);
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;

DO $wrap$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef('public.tithe_pool_reconcile(uuid,uuid[])'::regprocedure) INTO v_def;
  v_def := replace(v_def,
    E'BEGIN\n  -- ── money in ──',
    E'BEGIN\n  PERFORM set_config(''newtworks.tithe_reconciling'', ''on'', true);\n  -- ── money in ──');
  v_def := replace(v_def,
    E'  DROP TABLE _draw_should;\n',
    E'  DROP TABLE _draw_should;\n  PERFORM set_config(''newtworks.tithe_reconciling'', ''off'', true);\n');
  IF v_def NOT LIKE '%tithe_reconciling%on%' OR v_def NOT LIKE '%tithe_reconciling%off%' THEN
    RAISE EXCEPTION 'flag patch did not apply';
  END IF;
  EXECUTE v_def;
END
$wrap$;
