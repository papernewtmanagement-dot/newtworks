-- Outlook card, Peter 2026-09-22.
-- * The Instructions section becomes the info behind an (i) on the Give agent
--   access heading; the word Instructions goes.
-- * The Report Phishing troubleshooting steps become the info behind an (i) on
--   the Report Phishing heading.
-- A sub-item group can now carry "info": lines shown when its (i) is opened.
-- They are not checkboxes and never count toward finishing the card.
-- * The out of office section and the "Add new TM to Outlook" line came back
--   when the card was saved from an editor opened before they were moved. They
--   live on the out-of-office checklist item and the Team Adds the New Hire
--   card, so they come off here again.
UPDATE public.onboarding_step_templates t
   SET substeps = (
     SELECT jsonb_agg(
              CASE
                WHEN e ->> 'group' = 'Give agent access' THEN
                  e || jsonb_build_object('info',
                         (SELECT x -> 'items' FROM jsonb_array_elements(t.substeps) x
                          WHERE x ->> 'group' = 'Instructions' LIMIT 1))
                WHEN e ->> 'group' = 'Report Phishing' THEN
                  e || jsonb_build_object('info',
                         jsonb_build_array('If the “Report Phishing” button isn’t showing, troubleshoot:')
                         || (SELECT x -> 'items' FROM jsonb_array_elements(t.substeps) x
                             WHERE x ->> 'group' = 'If the “Report Phishing” button isn’t showing, troubleshoot' LIMIT 1))
                ELSE e
              END
              ORDER BY ord)
     FROM jsonb_array_elements(t.substeps) WITH ORDINALITY AS z(e, ord)
     WHERE COALESCE(e ->> 'group', '') NOT IN (
             'Instructions',
             'Create an out of office reply',
             'If the “Report Phishing” button isn’t showing, troubleshoot')
       AND NOT (e ->> 'group' IS NULL
                AND e -> 'items' = '["Add new TM to Outlook of all other team members"]'::jsonb))
 WHERE t.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND t.template_key = 'outlook'
   AND EXISTS (SELECT 1 FROM jsonb_array_elements(t.substeps) x WHERE x ->> 'group' = 'Instructions')
   AND EXISTS (SELECT 1 FROM jsonb_array_elements(t.substeps) x WHERE x ->> 'group' = 'Give agent access')
   AND EXISTS (SELECT 1 FROM jsonb_array_elements(t.substeps) x WHERE x ->> 'group' = 'Report Phishing')
   AND EXISTS (SELECT 1 FROM jsonb_array_elements(t.substeps) x
               WHERE x ->> 'group' = 'If the “Report Phishing” button isn’t showing, troubleshoot');
