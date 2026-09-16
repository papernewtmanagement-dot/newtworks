-- Item lists on the week scoreboard were ordered by date and customer only, so two
-- rows for the same customer on the same day could come back in either order and the
-- board would flicker between reads. Tie-break on the row id so a read is repeatable.
DO $mig$
DECLARE
  src text; newsrc text; hits int := 0;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
  FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
  WHERE ns.nspname = 'public' AND p.proname = 'rp_week_scoreboard_for';

  newsrc := src;

  IF position('ORDER BY on_date DESC, customer)' in newsrc) > 0 THEN
    newsrc := replace(newsrc, 'ORDER BY on_date DESC, customer)', 'ORDER BY on_date DESC, customer, id)');
    hits := hits + 1;
  END IF;
  IF position('ORDER BY quote_date DESC, customer_label)' in newsrc) > 0 THEN
    newsrc := replace(newsrc, 'ORDER BY quote_date DESC, customer_label)', 'ORDER BY quote_date DESC, customer_label, id)');
    hits := hits + 1;
  END IF;
  IF position('ORDER BY x.issued_date DESC, x.customer_label)' in newsrc) > 0 THEN
    newsrc := replace(newsrc, 'ORDER BY x.issued_date DESC, x.customer_label)', 'ORDER BY x.issued_date DESC, x.customer_label, x.id)');
    hits := hits + 1;
  END IF;
  IF position('ORDER BY l.occurred_on DESC, l.created_at DESC)' in newsrc) > 0 THEN
    newsrc := replace(newsrc, 'ORDER BY l.occurred_on DESC, l.created_at DESC)', 'ORDER BY l.occurred_on DESC, l.created_at DESC, l.id)');
    hits := hits + 1;
  END IF;

  IF hits < 4 THEN
    RAISE EXCEPTION 'Expected 4 item orderings in rp_week_scoreboard_for, found %. Another thread changed it. Re-read pg_proc before patching.', hits;
  END IF;

  EXECUTE newsrc;
END
$mig$;
