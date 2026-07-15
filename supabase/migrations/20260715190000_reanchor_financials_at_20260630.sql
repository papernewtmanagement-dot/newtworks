-- Re-anchor Financials at 6/30/2026 (was 4/30/2026)
-- Deletes 5,255 pre-cutover journal_entries (4,987 historical imports + 268 Newtworks-originated)
-- Deletes 23 opening_balances rows at 4/30/2026
-- Nulls out journal_entry_id refs on 32 source-doc rows so they can be re-posted if needed
-- Updates gl_cutover_date setting 2026-05-01 → 2026-07-01
-- Seeds new gl_anchor_date setting = 2026-06-30
-- Auto-closes 7 obsolete finance tasks

-- Row-count guard
DO $$
DECLARE v_hist int; v_gray int; v_total int; v_ob int;
BEGIN
  SELECT COUNT(*) INTO v_hist FROM journal_entries
    WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
      AND source LIKE 'historical_import%';
  SELECT COUNT(*) INTO v_gray FROM journal_entries
    WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
      AND source NOT LIKE 'historical_import%'
      AND entry_date < '2026-07-01';
  SELECT COUNT(*) INTO v_total FROM journal_entries
    WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
      AND entry_date < '2026-07-01';
  SELECT COUNT(*) INTO v_ob FROM opening_balances
    WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
      AND as_of_date='2026-04-30';
  RAISE NOTICE 'Pre-delete counts: historical=%, gray=%, total_pre_cutover=%, ob_0430=%', v_hist, v_gray, v_total, v_ob;
  IF v_hist <> 4987 OR v_gray <> 268 OR v_total <> 5255 OR v_ob <> 23 THEN
    RAISE EXCEPTION 'Row-count guard failed: hist=% (want 4987), gray=% (want 268), total=% (want 5255), ob=% (want 23). Aborting.', v_hist, v_gray, v_total, v_ob;
  END IF;
END $$;

-- Null out journal_entry_id FKs on downstream source-doc rows (23 comp_recap + 9 payroll_runs)
UPDATE public.comp_recap
   SET journal_entry_id = NULL,
       posted_at = NULL,
       notes = COALESCE(notes,'') || ' [reset by 20260715 re-anchor; pre-7/1 JE deleted]'
 WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
   AND journal_entry_id IN (
     SELECT id FROM journal_entries
      WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
        AND entry_date < '2026-07-01'
        AND source IN ('gl_entry_writer','claude_adjustment')
   );

UPDATE public.payroll_runs
   SET journal_entry_id = NULL,
       posted_at = NULL,
       notes = COALESCE(notes,'') || ' [reset by 20260715 re-anchor; pre-7/1 JE deleted]'
 WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
   AND journal_entry_id IN (
     SELECT id FROM journal_entries
      WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
        AND entry_date < '2026-07-01'
        AND source = 'payroll_gl_writer'
   );

-- Hard-delete all pre-cutover journal_entries (CASCADE drops journal_lines)
DELETE FROM public.journal_entries
 WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
   AND entry_date < '2026-07-01';

-- Delete 4/30 opening_balances (will be rebuilt at 6/30 in a separate workstream)
DELETE FROM public.opening_balances
 WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
   AND as_of_date='2026-04-30';

-- Bump cutover setting
UPDATE public.settings
   SET setting_value='2026-07-01'
 WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
   AND setting_key='gl_cutover_date';

-- Seed new anchor-date setting (used by refactored views in migration 2)
INSERT INTO public.settings (agency_id, setting_key, setting_value)
VALUES ('126794dd-25ff-47d2-a436-724499733365','gl_anchor_date','2026-06-30')
ON CONFLICT (agency_id, setting_key) DO UPDATE SET setting_value=EXCLUDED.setting_value;

-- Close 7 obsolete finance tasks made moot by the re-anchor
UPDATE public.tasks
   SET status='completed',
       completed_at=NOW(),
       updated_at=NOW()
 WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
   AND status IN ('open','in_progress')
   AND id IN (
     '6ac16fa1-b3f6-4fa6-983d-baa2b2e8c24f',
     '0a6bee04-4656-4332-9d64-f4ab106778ee',
     'b20c15ea-826a-4c64-ab9f-77fc59d3ae8a',
     '4c4f7aa5-e61d-4f41-93a4-c8f99ff2ae40',
     'f9e4203b-8570-4193-8eec-f9b3f3efd5bb',
     'fa1ac3f6-2baa-4dfd-91d4-d31fb8a384b9',
     '85422c91-7ebd-486c-80a9-ed5da79d3016'
   );

-- Post-verification
DO $$
DECLARE v_remaining int; v_ob_remaining int;
BEGIN
  SELECT COUNT(*) INTO v_remaining FROM journal_entries
    WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
      AND entry_date < '2026-07-01';
  SELECT COUNT(*) INTO v_ob_remaining FROM opening_balances
    WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
      AND as_of_date='2026-04-30';
  IF v_remaining <> 0 OR v_ob_remaining <> 0 THEN
    RAISE EXCEPTION 'Post-delete guard failed. Pre-7/1 JE remaining=%, 4/30 opening_balances remaining=%', v_remaining, v_ob_remaining;
  END IF;
  RAISE NOTICE 'Delete complete. Post-cutover JE count: %',
    (SELECT COUNT(*) FROM journal_entries WHERE agency_id='126794dd-25ff-47d2-a436-724499733365');
END $$;
