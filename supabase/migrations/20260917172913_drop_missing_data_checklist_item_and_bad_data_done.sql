-- 1. Rewrite get_weekly_cpr_requirements to stop counting bad_data_done in the
--    pre-2026-09-12 legacy miss total. Guarded: aborts unless exactly one
--    reference exists and the replacement removes it.
DO $mig$
DECLARE
  v_def text;
  v_new text;
  v_hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_weekly_cpr_requirements';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'get_weekly_cpr_requirements not found';
  END IF;

  v_hits := (length(v_def) - length(replace(v_def, 'bad_data_done', ''))) / length('bad_data_done');
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'expected exactly 1 bad_data_done reference, found %', v_hits;
  END IF;

  v_new := regexp_replace(
             v_def,
             '\s*\+\s*CASE WHEN COALESCE\(bad_data_done,\s*false\) THEN 0 ELSE 1 END',
             '',
             'g');

  IF position('bad_data_done' in v_new) > 0 THEN
    RAISE EXCEPTION 'bad_data_done still present after replacement';
  END IF;

  EXECUTE v_new;
END
$mig$;

-- 2. Drop the historical CPR column.
ALTER TABLE public.weekly_cpr_reports DROP COLUMN IF EXISTS bad_data_done;

-- 3. Delete the Missing Data checklist item and every row hanging off it.
DELETE FROM public.weekly_cpr_checklist
 WHERE item_id = '1d3cccfe-cc3c-4834-af04-0171e2f17e74';

DELETE FROM public.daily_checklist_ticks
 WHERE item_id = '1d3cccfe-cc3c-4834-af04-0171e2f17e74';

DELETE FROM public.checklist_items
 WHERE id = '1d3cccfe-cc3c-4834-af04-0171e2f17e74'
   AND agency_id = '126794dd-25ff-47d2-a436-724499733365';
