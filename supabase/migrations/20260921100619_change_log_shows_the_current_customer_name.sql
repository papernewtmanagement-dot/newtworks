-- The change history is append-only, so a customer renamed later (PG C. ->
-- PG Special Events Catering, Peter 2026-09-21) kept the old name on every past
-- change. The readers now show the record's name as it stands today, and fall
-- back to the name saved with the change only when the record is gone.

CREATE OR REPLACE FUNCTION public.change_current_subject(p_table text, p_row_id uuid, p_row jsonb, p_snapshot text)
RETURNS text
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(
    CASE p_table
      WHEN 'sales_log'              THEN (SELECT customer_label FROM public.sales_log WHERE id = p_row_id)
      WHEN 'sales_log_products'     THEN (SELECT customer_label FROM public.sales_log WHERE id = NULLIF(p_row ->> 'sales_log_id', '')::uuid)
      WHEN 'quote_log'              THEN (SELECT customer_label FROM public.quote_log WHERE id = p_row_id)
      WHEN 'quote_log_products'     THEN (SELECT customer_label FROM public.quote_log WHERE id = NULLIF(p_row ->> 'quote_log_id', '')::uuid)
      WHEN 'cancelation_log'        THEN (SELECT customer_label FROM public.cancelation_log WHERE id = p_row_id)
      WHEN 'retention_activity_log' THEN (SELECT customer_label FROM public.retention_activity_log WHERE id = p_row_id)
      WHEN 'fit_scorecards'         THEN (SELECT customer_first_name FROM public.fit_scorecards WHERE id = p_row_id)
    END,
    p_snapshot);
$function$;

DO $mig$
DECLARE v_def text; v_old text; v_new text;
BEGIN
  SELECT pg_get_functiondef('public.production_changes_for_range(uuid,date,date,boolean)'::regprocedure) INTO v_def;
  v_old := 'r.what, r.item, r.subject, r.owner_id, r.spot_note, r.rank';
  v_new := 'r.what, r.item, public.change_current_subject(r.table_name, r.row_id, COALESCE(r.new_row, r.old_row), r.subject) AS subject, r.owner_id, r.spot_note, r.rank';
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN RAISE EXCEPTION 'top block not found once'; END IF;
  v_def := replace(v_def, v_old, v_new);
  v_old := $o$'Policy'::text AS item, r.subject,$o$;
  v_new := $n$'Policy'::text AS item, public.change_current_subject(r.table_name, r.row_id, COALESCE(r.new_row, r.old_row), r.subject) AS subject,$n$;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN RAISE EXCEPTION 'issue block not found once'; END IF;
  v_def := replace(v_def, v_old, v_new);
  EXECUTE v_def;

  SELECT pg_get_functiondef('public.change_log_recent(integer,uuid,integer)'::regprocedure) INTO v_def;
  v_old := 'c.table_name, c.row_id, c.subject, c.changed_fields,';
  v_new := 'c.table_name, c.row_id, public.change_current_subject(c.table_name, c.row_id, COALESCE(c.new_row, c.old_row), c.subject), c.changed_fields,';
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN RAISE EXCEPTION 'recent block not found once'; END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $mig$;
