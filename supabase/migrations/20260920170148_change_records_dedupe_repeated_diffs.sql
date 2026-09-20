-- One click that touches many records repeats the same before-and-after over
-- and over (a bulk void wrote "status: Credited to Void" four times). Collapse
-- identical field/before/after triples inside a transaction and carry a count
-- instead. Also fixes "a activity" reading as "an activity".

CREATE OR REPLACE FUNCTION public.production_changes_for_range(p_agency_id uuid, p_start date, p_end date)
RETURNS TABLE(txid bigint, changed_at timestamptz, team_member_id uuid, who text, what text,
              item text, subject text, changed_fields text[], changes jsonb,
              row_count integer, line text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH gate AS (
    SELECT (public.current_team_member_id() IS NOT NULL
            OR current_user IN ('postgres', 'supabase_admin', 'service_role')) AS ok
  ),
  raw AS (
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
      FROM public.change_log c, gate g
     WHERE g.ok
       AND c.agency_id = p_agency_id
       AND c.changed_at >= p_start::timestamptz
       AND c.changed_at <  (p_end + 1)::timestamptz
       AND lower(c.action) IN ('update', 'delete')
       AND COALESCE(c.via, '') <> 'automation'
  ),
  -- Every field that moved anywhere inside one click. A sale and the policy
  -- line under it are one click, so both sets of values belong on one line.
  -- The same move repeated across records is shown once with a count.
  diff_rows AS (
    SELECT r.txid, e.val, count(*)::integer AS n, min(r.rank * 1000 + e.ord) AS ord
      FROM raw r
      CROSS JOIN LATERAL jsonb_array_elements(
             public.change_diff(p_agency_id, r.changed_fields, r.old_row, r.new_row)
           ) WITH ORDINALITY AS e(val, ord)
     WHERE lower(r.action) = 'update'
     GROUP BY r.txid, e.val
  ),
  diffs AS (
    SELECT d.txid,
           jsonb_agg(d.val || jsonb_build_object('count', d.n) ORDER BY d.ord) AS changes
      FROM diff_rows d GROUP BY d.txid
  ), top AS (
    SELECT DISTINCT ON (r.txid)
           r.txid, r.changed_at, r.changed_by_team_member_id, r.changed_by_label,
           r.what, r.item, r.subject, r.changed_fields,
           NULLIF(btrim(COALESCE(r.new_row->>'spot_check_note', '')), '') AS spot_note
      FROM raw r ORDER BY r.txid, r.rank, r.changed_at
  ), grouped AS (
    SELECT t.*,
           COALESCE(d.changes, '[]'::jsonb) AS changes,
           (SELECT count(*) FROM raw r2 WHERE r2.txid = t.txid)::integer AS row_count
      FROM top t LEFT JOIN diffs d ON d.txid = t.txid
  )
  SELECT g.txid, g.changed_at, g.changed_by_team_member_id,
         COALESCE(g.changed_by_label, 'Unknown') AS who, g.what, g.item,
         g.subject, g.changed_fields, g.changes, g.row_count,
         (to_char(g.changed_at AT TIME ZONE 'America/Chicago', 'HH12:MI am') || ' · ' ||
          COALESCE(g.changed_by_label, 'Unknown') || ' ' || g.what ||
          CASE WHEN lower(g.item) ~ '^[aeiou]' THEN ' an ' ELSE ' a ' END || lower(g.item) ||
          COALESCE(' — ' || g.subject, '') ||
          COALESCE(' (' || (
            SELECT string_agg((c.val->>'label') || ': ' || (c.val->>'before') || ' → ' || (c.val->>'after')
                              || CASE WHEN (c.val->>'count')::int > 1 THEN ' ×' || (c.val->>'count') ELSE '' END,
                              '; ' ORDER BY c.ord)
              FROM jsonb_array_elements(g.changes) WITH ORDINALITY AS c(val, ord)
             WHERE c.ord <= 6
          ) || CASE WHEN jsonb_array_length(g.changes) > 6
                    THEN '; and ' || (jsonb_array_length(g.changes) - 6) || ' more' ELSE '' END
          || ')', '') ||
          CASE WHEN g.row_count > 1 THEN ' [' || g.row_count || ' records]' ELSE '' END ||
          COALESCE(' — spot-check: ' || g.spot_note, '')) AS line
    FROM grouped g
   ORDER BY g.changed_at DESC;
$function$;
