-- ============================================================================
-- Discover Tithe CC 3208 — cycle-month attribution + delete June plug
-- ============================================================================
-- Peter's mental model: Christ+Actmin charges that post on the 1st/2nd of a month
-- belong to the preceding month's tithe giving cycle (they were Peter's tithe FOR
-- the prior month, just cleared on the CC on day 1-2 of the following month).
--
-- Shift entry_date on 6 straddling JEs so P&L attributes them correctly:
--   Christ+Actmin Feb 1  → entry_date 2026-01-31 (attribute to January)
--   Christ+Actmin Mar 2  → entry_date 2026-02-28 (attribute to February)
--   Christ+Actmin Apr 1-2 → entry_date 2026-03-31 (attribute to March)
--
-- credit_transactions.transaction_date stays as-is (audit truth of when CC charged).
--
-- Also DELETE the June aggregate plug (pf4o_tithe_reconcile "Aggregate June tithe cycle
-- Church + Actmin") — Peter's directive: never use plugs.
-- ============================================================================

DO $shift$
DECLARE
  n_shifted int;
  n_plug_deleted int;
BEGIN
  -- Step 1: Shift 6 JE entry_dates to prior-month attribution
  UPDATE public.journal_entries
  SET entry_date = CASE
    WHEN id IN (
      '23c29783-0a43-4080-ae2a-f607c1696f59',  -- PAYPAL ACTMIN Feb 1
      'ad256294-f2e3-490d-b4b2-ff6862ac853d'   -- GIV CHRIST Feb 1
    ) THEN '2026-01-31'::date
    WHEN id IN (
      '59e40af8-d37b-4920-8c51-0c5d320a8fea',  -- PAYPAL ACTMIN Mar 2
      'a2df417b-a367-44d1-90a8-cb9ffba3b280'   -- GIV CHRIST Mar 2
    ) THEN '2026-02-28'::date
    WHEN id IN (
      '378cc73a-59fa-4f30-85e7-9d594bb8befc',  -- GIV CHRIST Apr 1
      'f670f4fd-de70-4a5d-8e55-1e196f3148d2'   -- PAYPAL ACTMIN Apr 2
    ) THEN '2026-03-31'::date
  END
  WHERE id IN (
    '23c29783-0a43-4080-ae2a-f607c1696f59',
    'ad256294-f2e3-490d-b4b2-ff6862ac853d',
    '59e40af8-d37b-4920-8c51-0c5d320a8fea',
    'a2df417b-a367-44d1-90a8-cb9ffba3b280',
    '378cc73a-59fa-4f30-85e7-9d594bb8befc',
    'f670f4fd-de70-4a5d-8e55-1e196f3148d2'
  );

  GET DIAGNOSTICS n_shifted = ROW_COUNT;
  RAISE NOTICE 'Shifted % JE entry_dates to prior-month tithe cycle attribution', n_shifted;

  -- Step 2: Delete the June Church+Actmin plug
  WITH jun_plug AS (
    SELECT je.id FROM public.journal_entries je
    WHERE je.source = 'pf4o_tithe_reconcile'
      AND je.agency_id = '126794dd-25ff-47d2-a436-724499733365'
      AND je.entry_date >= '2026-06-01' AND je.entry_date < '2026-07-01'
      AND je.description ILIKE '%Church%'
  ), del_lines AS (
    DELETE FROM public.journal_lines WHERE journal_entry_id IN (SELECT id FROM jun_plug) RETURNING 1
  )
  DELETE FROM public.journal_entries WHERE id IN (SELECT id FROM jun_plug);

  GET DIAGNOSTICS n_plug_deleted = ROW_COUNT;
  RAISE NOTICE 'Deleted % June Church+Actmin plug JEs', n_plug_deleted;
END $shift$;
