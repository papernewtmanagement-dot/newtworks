-- The out of office steps now live on the out-of-office checklist item
-- (checklist_items.item_key = 'ooo'), so the Outlook card drops that section.
UPDATE public.onboarding_step_templates t
   SET substeps = (
     SELECT jsonb_agg(e ORDER BY ord)
     FROM jsonb_array_elements(t.substeps) WITH ORDINALITY AS x(e, ord)
     WHERE COALESCE(e ->> 'group', '') <> 'Create an out of office reply')
 WHERE t.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND t.template_key = 'outlook'
   AND EXISTS (SELECT 1 FROM jsonb_array_elements(t.substeps) e
               WHERE e ->> 'group' = 'Create an out of office reply');
