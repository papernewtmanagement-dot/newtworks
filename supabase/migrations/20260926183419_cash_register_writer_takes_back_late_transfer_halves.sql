-- Cash register writer: take back a transfer half that posted alone (Peter 2026-09-26).
-- 1. The pairing step only looked at rows not yet in the ledger. The alert ingestor runs every
--    3 hours and the settle wait is 90 minutes, so the two halves of one transfer can land in
--    different runs and each post alone as an unclassified guess. Sept 21 2026: $14,553.92 moved
--    from 3977 to 4335 showed as both agency expense and agency income. The writer now pairs a
--    half that posted as an unclassified guess, still waiting on its statement, with its other half.
-- 2. A row the statement writer took back out of the ledger (status 'reconciled') no longer counts
--    as waiting to post, so the cash register writer cannot post it again.
DO $mig$
DECLARE
  v_def text := pg_get_functiondef('public.cash_register_gl_writer(uuid,boolean,date,integer)'::regprocedure);
  v_d_old text := $d$c.status IS DISTINCT FROM 'possible_transfer'$d$;
  v_d_new text := $d$COALESCE(c.status, '') NOT IN ('possible_transfer', 'reconciled')$d$;
  v_a_old text := $a$  v_reg_entity_name text; v_acct_entity_name text;
BEGIN
$a$;
  v_a_new text := $a$  v_reg_entity_name text; v_acct_entity_name text;
  v_pair_ids uuid[] := ARRAY[]::uuid[];
  v_pair_ledger_ids uuid[] := ARRAY[]::uuid[];
  v_pairs jsonb := '[]'::jsonb;
BEGIN
$a$;
  v_b_old text := $b$  v_count_suppressed := COALESCE(array_length(v_suppressed_ids,1), 0);
$b$;
  v_b_new text := $b$  v_count_suppressed := COALESCE(array_length(v_suppressed_ids,1), 0);

  -- Late transfer halves (Peter 2026-09-26). The pairing above only sees rows that are not in
  -- the ledger yet. The alert ingestor runs every 3 hours and the settle wait is 90 minutes, so
  -- the two halves of one transfer can land in different runs and each post alone as an
  -- unclassified guess (Sept 21 2026: $14,553.92 moved from 3977 to 4335 showed as both agency
  -- expense and agency income). Here a half that posted as an unclassified guess, still waiting
  -- on its statement, is paired with its other half, posted or not, when there is exactly one
  -- match: same amount, opposite direction, a different account, dates at most one day apart.
  -- The guess comes back out of the ledger and both halves wait for the statement, the same as a
  -- pair caught on arrival. A row someone classified, tagged, drew from the tithe pool or matched
  -- to an Amazon order is never touched.
  WITH pool AS MATERIALIZED (
    SELECT c.id, c.txn_date, c.amount, c.direction, c.account_last4, l.id AS ledger_id
    FROM cash_register_preliminary c
    LEFT JOIN ledger l ON l.cash_register_id = c.id
    WHERE c.agency_id = p_agency_id
      AND c.txn_date >= p_from
      AND c.amount > 0
      AND c.created_at < now() - (p_settle_minutes || ' minutes')::interval
      AND COALESCE(c.status, '') NOT IN ('possible_transfer', 'reconciled')
      AND NOT (c.id = ANY(COALESCE(v_suppressed_ids, ARRAY[]::uuid[])))
      AND (l.id IS NULL
           OR (l.source = 'cash_register_gl_writer'
               AND l.statement_id IS NULL
               AND l.classification_status = 'unclassified'
               AND l.tithe_draw_source IS DISTINCT FROM 'manual'
               AND NOT EXISTS (SELECT 1 FROM transaction_tags tt WHERE tt.journal_line_id = l.id)
               AND NOT EXISTS (SELECT 1 FROM amazon_orders ao WHERE ao.matched_ledger_id = l.id)))
  ),
  all_pairs AS MATERIALIZED (
    SELECT a.id AS a_id, b.id AS b_id, a.ledger_id AS a_led, b.ledger_id AS b_led, a.amount,
           CASE WHEN a.direction = 'debit' THEN a.account_last4 ELSE b.account_last4 END AS from_last4,
           CASE WHEN a.direction = 'debit' THEN b.account_last4 ELSE a.account_last4 END AS to_last4,
           least(a.txn_date, b.txn_date) AS pair_date
    FROM pool a
    JOIN pool b ON b.amount = a.amount
               AND b.direction <> a.direction
               AND b.account_last4 <> a.account_last4
               AND abs(b.txn_date - a.txn_date) <= 1
               AND a.id < b.id
  ),
  member_counts AS MATERIALIZED (
    SELECT m.id, count(*) AS n
    FROM (SELECT a_id AS id FROM all_pairs UNION ALL SELECT b_id FROM all_pairs) m
    GROUP BY m.id
  ),
  clean AS MATERIALIZED (
    SELECT p.*
    FROM all_pairs p
    JOIN member_counts ma ON ma.id = p.a_id AND ma.n = 1
    JOIN member_counts mb ON mb.id = p.b_id AND mb.n = 1
    WHERE p.a_led IS NOT NULL OR p.b_led IS NOT NULL
  ),
  members AS (
    SELECT a_id AS id, a_led AS led FROM clean
    UNION ALL
    SELECT b_id, b_led FROM clean
  )
  SELECT COALESCE((SELECT array_agg(id) FROM members), ARRAY[]::uuid[]),
         COALESCE((SELECT array_agg(led) FROM members WHERE led IS NOT NULL), ARRAY[]::uuid[]),
         COALESCE((SELECT jsonb_agg(jsonb_build_object(
                     'date', pair_date, 'amount', amount, 'from', from_last4, 'to', to_last4,
                     'ledger_rows_taken_back', (a_led IS NOT NULL)::int + (b_led IS NOT NULL)::int)
                   ORDER BY pair_date, amount) FROM clean), '[]'::jsonb)
  INTO v_pair_ids, v_pair_ledger_ids, v_pairs;

  IF COALESCE(array_length(v_pair_ids, 1), 0) > 0 THEN
    IF NOT p_dry_run THEN
      DELETE FROM ledger WHERE id = ANY(v_pair_ledger_ids);
      UPDATE cash_register_preliminary
      SET status = 'possible_transfer',
          coding_question = 'Looks like a transfer between two of our own accounts — waiting for the statement to confirm.',
          updated_at = now()
      WHERE id = ANY(v_pair_ids);
    END IF;
    v_suppressed_ids := COALESCE(v_suppressed_ids, ARRAY[]::uuid[]) || v_pair_ids;
    v_count_suppressed := COALESCE(array_length(v_suppressed_ids,1), 0);
  END IF;
$b$;
  v_c_old text := $c$    'suppressed_transfer', v_count_suppressed,
$c$;
  v_c_new text := $c$    'suppressed_transfer', v_count_suppressed,
    'transfer_pairs_taken_back', v_pairs,
$c$;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_d_old, ''))) / length(v_d_old) <> 2 THEN
    RAISE EXCEPTION 'anchor D (status filter) not found exactly twice';
  END IF;
  v_def := replace(v_def, v_d_old, v_d_new);
  IF (length(v_def) - length(replace(v_def, v_a_old, ''))) / length(v_a_old) <> 1 THEN
    RAISE EXCEPTION 'anchor A (declare block) not found exactly once';
  END IF;
  IF (length(v_def) - length(replace(v_def, v_b_old, ''))) / length(v_b_old) <> 1 THEN
    RAISE EXCEPTION 'anchor B (suppressed count) not found exactly once';
  END IF;
  IF (length(v_def) - length(replace(v_def, v_c_old, ''))) / length(v_c_old) <> 1 THEN
    RAISE EXCEPTION 'anchor C (result object) not found exactly once';
  END IF;
  v_def := replace(replace(replace(v_def, v_a_old, v_a_new), v_b_old, v_b_new), v_c_old, v_c_new);
  EXECUTE v_def;
END $mig$;
