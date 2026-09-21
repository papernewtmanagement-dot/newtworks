-- One click that touched two teammates' records (Charles C.: Stephanie's
-- Policy Change and Tommy's save removed together) was one entry under
-- whichever record sorted first, so the other teammate never saw theirs.
-- Edit entries are now one per click per teammate.
DO $mig$
DECLARE d text;
  PROCEDURE_NAME text;
BEGIN
  SELECT pg_get_functiondef('public.production_changes_for_range(uuid,date,date,boolean)'::regprocedure) INTO d;
  CREATE TEMP TABLE _p(n int, o text, r text) ON COMMIT DROP;
  INSERT INTO _p VALUES
  (1, $o$    SELECT r.txid, e.val, count(*)::integer AS n, min(r.rank * 1000 + e.ord) AS ord
      FROM change_raw r$o$, $r$    SELECT r.txid, r.owner_id, e.val, count(*)::integer AS n, min(r.rank * 1000 + e.ord) AS ord
      FROM change_raw r$r$),
  (2, $o$     GROUP BY r.txid, e.val$o$, $r$     GROUP BY r.txid, r.owner_id, e.val$r$),
  (3, $o$    SELECT d.txid, jsonb_agg(d.val || jsonb_build_object('count', d.n) ORDER BY d.ord) AS changes
      FROM diff_rows d GROUP BY d.txid$o$, $r$    SELECT d.txid, d.owner_id, jsonb_agg(d.val || jsonb_build_object('count', d.n) ORDER BY d.ord) AS changes
      FROM diff_rows d GROUP BY d.txid, d.owner_id$r$),
  (4, $o$    SELECT DISTINCT ON (r.txid)$o$, $r$    SELECT DISTINCT ON (r.txid, r.owner_id)$r$),
  (5, $o$      FROM change_raw r ORDER BY r.txid, r.rank, r.changed_at$o$, $r$      FROM change_raw r ORDER BY r.txid, r.owner_id, r.rank, r.changed_at$r$),
  (6, $o$           (SELECT array_agg(DISTINCT f) FROM change_raw r2, unnest(r2.edit_fields) f WHERE r2.txid = t.txid) AS fields,
           (SELECT count(*) FROM change_raw r2 WHERE r2.txid = t.txid)::integer AS row_count
      FROM top t LEFT JOIN diffs d ON d.txid = t.txid$o$,
      $r$           (SELECT array_agg(DISTINCT f) FROM change_raw r2, unnest(r2.edit_fields) f
             WHERE r2.txid = t.txid AND r2.owner_id IS NOT DISTINCT FROM t.owner_id) AS fields,
           (SELECT count(*) FROM change_raw r2
             WHERE r2.txid = t.txid AND r2.owner_id IS NOT DISTINCT FROM t.owner_id)::integer AS row_count
      FROM top t LEFT JOIN diffs d ON d.txid = t.txid AND d.owner_id IS NOT DISTINCT FROM t.owner_id$r$);
  DECLARE p record;
  BEGIN
    FOR p IN SELECT * FROM _p ORDER BY n LOOP
      IF (length(d) - length(replace(d, p.o, ''))) / length(p.o) <> 1 THEN
        RAISE EXCEPTION 'edit % did not match exactly once', p.n;
      END IF;
      d := replace(d, p.o, p.r);
    END LOOP;
  END;
  EXECUTE d;
END $mig$;
