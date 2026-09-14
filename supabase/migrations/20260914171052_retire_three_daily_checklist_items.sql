-- Peter 2026-09-14: remove three team items from the daily checklist.
-- Retire by effective_to (the designed mechanism) so the week ending 2026-09-12,
-- which already has ticks and a CPR audit row for these items, is unchanged.
UPDATE public.checklist_items
SET effective_to = DATE '2026-09-12', updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND item_key IN ('kickoff', 'resumes', 'ecrm_required_fields')
  AND scope = 'team';
