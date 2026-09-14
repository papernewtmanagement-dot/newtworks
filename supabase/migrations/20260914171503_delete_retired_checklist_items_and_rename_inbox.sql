-- Peter 2026-09-14: hard delete, not retire.
-- Team items: kickoff, resumes, ecrm_required_fields.
-- Personal items: checkins, scorecards.
-- Personal item inbox retitled "Inbox cleared".

DELETE FROM public.daily_checklist_ticks
WHERE item_id IN (
  SELECT id FROM public.checklist_items
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND item_key IN ('kickoff','resumes','ecrm_required_fields','checkins','scorecards')
);

DELETE FROM public.weekly_cpr_checklist
WHERE item_id IN (
  SELECT id FROM public.checklist_items
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND item_key IN ('kickoff','resumes','ecrm_required_fields','checkins','scorecards')
);

DELETE FROM public.checklist_items
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND item_key IN ('kickoff','resumes','ecrm_required_fields','checkins','scorecards');

UPDATE public.checklist_items
SET title = 'Inbox cleared', updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND item_key = 'inbox' AND scope = 'personal';
