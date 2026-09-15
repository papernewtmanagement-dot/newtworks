CREATE OR REPLACE FUNCTION public.production_change_digest_daily(p_agency_id uuid, p_recipe_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_day date := public.rp_today_central();
  v_ref text; v_lines text[] := ARRAY[]::text[]; v_msg text; v_n integer := 0; rec RECORD; v_id uuid;
BEGIN
  v_ref := 'production:change_digest:' || v_day::text;

  FOR rec IN
    WITH raw AS (
      SELECT c.*,
             CASE c.table_name
               WHEN 'sales_log' THEN 'Sale' WHEN 'sales_log_products' THEN 'Sold policy'
               WHEN 'quote_log' THEN 'Quote' WHEN 'quote_log_products' THEN 'Quoted product'
               WHEN 'cancelation_log' THEN 'Cancelation'
               WHEN 'retention_activity_log' THEN 'Activity'
               WHEN 'fit_scorecards' THEN 'Conversation score' ELSE c.table_name END AS item,
             CASE c.table_name
               WHEN 'sales_log' THEN 1 WHEN 'quote_log' THEN 1 WHEN 'cancelation_log' THEN 1
               WHEN 'fit_scorecards' THEN 1 WHEN 'retention_activity_log' THEN 2 ELSE 3 END AS rank,
             CASE
               WHEN lower(c.action) = 'delete' THEN 'removed'
               WHEN lower(c.action) = 'update' AND COALESCE(c.new_row->>'status','') IN ('void','voided')
                    AND COALESCE(c.old_row->>'status','') NOT IN ('void','voided') THEN 'removed'
               ELSE 'edited' END AS what
        FROM public.change_log c
       WHERE c.agency_id = p_agency_id
         AND c.changed_at >= v_day::timestamptz
         AND c.changed_at <  (v_day + 1)::timestamptz
         AND lower(c.action) IN ('update', 'delete')
         AND COALESCE(c.via, '') <> 'automation'
    ), top AS (
      SELECT DISTINCT ON (r.txid) r.txid, r.changed_at, r.changed_by_label, r.what, r.item, r.subject, r.changed_fields
        FROM raw r ORDER BY r.txid, r.rank, r.changed_at
    )
    SELECT t.*, (SELECT count(*) FROM raw r2 WHERE r2.txid = t.txid) AS row_count
      FROM top t ORDER BY t.changed_at
  LOOP
    v_n := v_n + 1;
    v_lines := v_lines || (
      to_char(rec.changed_at AT TIME ZONE 'America/Chicago', 'HH12:MI am') || ' · ' ||
      COALESCE(rec.changed_by_label, 'Unknown') || ' ' || rec.what || ' a ' || lower(rec.item) ||
      COALESCE(' — ' || rec.subject, '') ||
      CASE WHEN rec.what = 'edited' AND rec.changed_fields IS NOT NULL AND array_length(rec.changed_fields, 1) > 0
           THEN ' (' || array_to_string(rec.changed_fields, ', ') || ')' ELSE '' END ||
      CASE WHEN rec.row_count > 1 THEN ' [' || rec.row_count || ' records]' ELSE '' END);
  END LOOP;

  IF v_n = 0 THEN
    RETURN jsonb_build_object('ok', true, 'records_processed', 0, 'output_summary', 'no edits or removals today');
  END IF;

  v_msg := v_n || ' change' || CASE WHEN v_n = 1 THEN '' ELSE 's' END ||
           ' to production records on ' || to_char(v_day, 'Mon FMDD') || E':\n\n' ||
           array_to_string(v_lines, E'\n') ||
           E'\n\nThe full before-and-after is on the Changes tab.';

  SELECT id INTO v_id FROM public.alerts
   WHERE agency_id = p_agency_id AND module_reference = v_ref LIMIT 1;

  IF v_id IS NULL THEN
    INSERT INTO public.alerts (id, agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved, created_at)
    VALUES (gen_random_uuid(), p_agency_id, 'production_change_digest', 'low',
            'Production edits and removals — ' || to_char(v_day, 'Mon FMDD'), v_msg, v_ref, false, false, now());
  ELSE
    UPDATE public.alerts SET message = v_msg, is_read = false, is_resolved = false WHERE id = v_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'records_processed', v_n,
    'output_summary', v_n || ' edit/removal(s) summarized for ' || v_day::text);
END $function$;
