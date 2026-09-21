-- Peter 2026-09-21, round three.
--  * Spot-check notes are their own kind of entry (kind 'spot_check'), their
--    own card on the CPR and their own toggle on the Changes tab. They no
--    longer ride on the end of an edit line.
--  * Every entry carries the customer's phone last four, as the record stands
--    today, so a customer name can open the household popup.

CREATE OR REPLACE FUNCTION public.change_current_phone(p_table text, p_row_id uuid, p_row jsonb)
RETURNS text
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(
    CASE p_table
      WHEN 'sales_log'              THEN (SELECT phone_last4 FROM public.sales_log WHERE id = p_row_id)
      WHEN 'sales_log_products'     THEN (SELECT phone_last4 FROM public.sales_log WHERE id = NULLIF(p_row ->> 'sales_log_id', '')::uuid)
      WHEN 'quote_log'              THEN (SELECT phone_last4 FROM public.quote_log WHERE id = p_row_id)
      WHEN 'quote_log_products'     THEN (SELECT phone_last4 FROM public.quote_log WHERE id = NULLIF(p_row ->> 'quote_log_id', '')::uuid)
      WHEN 'cancelation_log'        THEN (SELECT phone_last4 FROM public.cancelation_log WHERE id = p_row_id)
      WHEN 'retention_activity_log' THEN (SELECT phone_last4 FROM public.retention_activity_log WHERE id = p_row_id)
    END,
    NULLIF(p_row ->> 'phone_last4', ''));
$function$;

DO $mig$
DECLARE d text;
  PROCEDURE_NOTE text;
  FUNCTION_OK boolean;
BEGIN
  SELECT pg_get_functiondef('public.production_changes_for_range(uuid,date,date,boolean)'::regprocedure) INTO d;

  -- helper: replace exactly once or stop
  CREATE TEMP TABLE IF NOT EXISTS _pairs(n int, o text, r text) ON COMMIT DROP;
  DELETE FROM _pairs;
  INSERT INTO _pairs VALUES
  (1, 'policy jsonb, line text)', 'policy jsonb, line text, phone_last4 text)'),
  (2, $o$AS spot_note
      FROM scoped s$o$, $r$AS spot_note,
           public.change_current_phone(s.table_name, s.row_id, COALESCE(s.new_row, s.old_row)) AS phone
      FROM scoped s$r$),
  (3, $o$AS policy,
           r.rank
      FROM raw r$o$, $r$AS policy,
           r.rank, r.phone
      FROM raw r$r$),
  (4, 'r.owner_id, r.spot_note, r.rank
      FROM change_raw r', 'r.owner_id, r.spot_note, r.rank, r.phone
      FROM change_raw r'),
  (5, $o$WHERE t.what <> 'edited' OR d.changes IS NOT NULL OR t.spot_note IS NOT NULL$o$,
      $r$WHERE t.what <> 'edited' OR d.changes IS NOT NULL$r$),
  (6, $o$d.owner_id, d.fields AS changed_fields, d.changes, d.row_count, d.spot_note,$o$,
      $r$d.owner_id, d.fields AS changed_fields, d.changes, d.row_count, NULL::text AS spot_note,$r$),
  (7, $o$ ||
            COALESCE(' — spot-check: ' || d.spot_note, '')) AS line
      FROM deduped d$o$, $r$) AS line, d.phone
      FROM deduped d$r$),
  (8, $o$) AS line
      FROM issues i
  )$o$, $r$) AS line, i.phone
      FROM issues i
  ),
  -- ---------- Spot-check notes: one entry per note ----------
  spot_out AS (
    SELECT DISTINCT ON (r.owner_id, public.change_current_subject(r.table_name, r.row_id, COALESCE(r.new_row, r.old_row), r.subject), r.spot_note)
           r.txid, r.changed_at, 'spot_check'::text AS kind, 'noted'::text AS what, r.item,
           public.change_current_subject(r.table_name, r.row_id, COALESCE(r.new_row, r.old_row), r.subject) AS subject,
           r.changed_by_team_member_id AS actor_id, COALESCE(r.changed_by_label, 'Unknown') AS who,
           r.owner_id, ARRAY['spot_check_note']::text[] AS changed_fields, '[]'::jsonb AS changes,
           1 AS row_count, r.spot_note, NULL::jsonb AS policy,
           (to_char(r.changed_at AT TIME ZONE 'America/Chicago', 'HH12:MI am') || ' · ' ||
            COALESCE(r.changed_by_label, 'Unknown') || ' left a spot-check note on ' ||
            CASE WHEN lower(r.item) ~ '^[aeiou]' THEN 'an ' ELSE 'a ' END || lower(r.item) ||
            COALESCE(' — ' || public.change_current_subject(r.table_name, r.row_id, COALESCE(r.new_row, r.old_row), r.subject), '') ||
            ': ' || r.spot_note) AS line,
           r.phone
      FROM raw r
     WHERE 'spot_check_note' = ANY(COALESCE(r.changed_fields, ARRAY[]::text[]))
       AND r.spot_note IS NOT NULL
       AND r.spot_note IS DISTINCT FROM NULLIF(btrim(COALESCE(r.old_row ->> 'spot_check_note', '')), '')
     ORDER BY r.owner_id, public.change_current_subject(r.table_name, r.row_id, COALESCE(r.new_row, r.old_row), r.subject), r.spot_note, r.changed_at
  )$r$),
  (9, $o$o.policy, o.line
    FROM (SELECT * FROM changes_out UNION ALL SELECT * FROM issues_out) o$o$,
      $r$o.policy, o.line, o.phone
    FROM (SELECT * FROM changes_out UNION ALL SELECT * FROM issues_out UNION ALL SELECT * FROM spot_out) o$r$);

  DECLARE p record;
  BEGIN
    FOR p IN SELECT * FROM _pairs ORDER BY n LOOP
      IF (length(d) - length(replace(d, p.o, ''))) / length(p.o) <> 1 THEN
        RAISE EXCEPTION 'production_changes_for_range edit % did not match exactly once', p.n;
      END IF;
      d := replace(d, p.o, p.r);
    END LOOP;
  END;

  DROP FUNCTION public.production_changes_for_day(uuid, date);
  DROP FUNCTION public.production_changes_for_range(uuid, date, date, boolean);
  EXECUTE replace(d, 'CREATE OR REPLACE FUNCTION', 'CREATE FUNCTION');

  -- change_log_recent carries the phone too
  SELECT pg_get_functiondef('public.change_log_recent(integer,uuid,integer)'::regprocedure) INTO d;
  IF position('new_row jsonb)' IN d) = 0 OR position(E'c.old_row, c.new_row\n    FROM public.change_log c' IN d) = 0 THEN
    RAISE EXCEPTION 'change_log_recent is not the expected shape';
  END IF;
  d := replace(d, 'new_row jsonb)', 'new_row jsonb, phone_last4 text)');
  d := replace(d, E'c.old_row, c.new_row\n    FROM public.change_log c',
                  E'c.old_row, c.new_row,\n         public.change_current_phone(c.table_name, c.row_id, COALESCE(c.new_row, c.old_row))\n    FROM public.change_log c');
  DROP FUNCTION public.change_log_recent(integer, uuid, integer);
  EXECUTE replace(d, 'CREATE OR REPLACE FUNCTION', 'CREATE FUNCTION');
END $mig$;

CREATE FUNCTION public.production_changes_for_day(p_agency_id uuid, p_day date DEFAULT NULL::date)
 RETURNS TABLE(txid bigint, changed_at timestamp with time zone, kind text, what text, item text,
               subject text, actor_id uuid, who text, owner_id uuid, owner_name text,
               changed_fields text[], changes jsonb, row_count integer, spot_note text,
               policy jsonb, line text, phone_last4 text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT r.*
    FROM public.production_changes_for_range(
           p_agency_id,
           COALESCE(p_day, public.rp_today_central()),
           COALESCE(p_day, public.rp_today_central()),
           false) r
   ORDER BY r.changed_at DESC;
$function$;

GRANT EXECUTE ON FUNCTION public.production_changes_for_range(uuid, date, date, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.production_changes_for_day(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.change_log_recent(integer, uuid, integer) TO authenticated;
