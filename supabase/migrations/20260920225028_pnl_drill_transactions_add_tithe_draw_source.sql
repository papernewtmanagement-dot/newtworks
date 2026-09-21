-- Adds tithe_draw_source to the P&L drill feed so the screen can show whether a
-- tithe draw was set by a rule, by hand, or excluded. Callers unchanged since the
-- last rebuild today: only src/modules/Financials.jsx, read by field name.
DO $wrap$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef('public.pnl_drill_transactions(uuid,text,text,text,date,date)'::regprocedure) INTO v_def;
  v_new := v_def;
  v_new := replace(v_new, 'tithe_draw_amount numeric)', 'tithe_draw_amount numeric, tithe_draw_source text)');
  v_new := replace(v_new, 'l.tithe_draw_amount AS tithe_draw_amount', E'l.tithe_draw_amount AS tithe_draw_amount,\n      l.tithe_draw_source AS tithe_draw_source');
  v_new := replace(v_new, 'NULL::numeric AS tithe_draw_amount', E'NULL::numeric AS tithe_draw_amount,\n      NULL::text AS tithe_draw_source');
  v_new := replace(v_new, E'cash_register_id, business_entity_id, tithe_draw_amount\n  FROM combined', E'cash_register_id, business_entity_id, tithe_draw_amount, tithe_draw_source\n  FROM combined');
  -- return list 1, journal side 2 (column and alias), prior-year side 1, final select 1
  IF (length(v_new) - length(replace(v_new, 'tithe_draw_source', ''))) / length('tithe_draw_source') <> 5 THEN
    RAISE EXCEPTION 'expected 5 tithe_draw_source occurrences';
  END IF;
  DROP FUNCTION public.pnl_drill_transactions(uuid,text,text,text,date,date);
  EXECUTE v_new;
  GRANT EXECUTE ON FUNCTION public.pnl_drill_transactions(uuid, text, text, text, date, date) TO authenticated, anon;
END
$wrap$;
