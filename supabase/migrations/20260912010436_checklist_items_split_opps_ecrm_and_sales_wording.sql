-- Peter 2026-09-11: campaign leads = per SALES team member (not acquisition);
-- split ECRM hygiene into three items; split Missing Phone / Missing Data out of the
-- Opportunity Lists item; add "every active opportunity has a task".
-- Nothing has ticked yet (items effective 2026-09-12), so edits are in place.

UPDATE public.checklist_items
   SET title = '10 campaign leads converted per sales team member', updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND item_key = 'campaign_leads';

UPDATE public.checklist_items
   SET title = 'Opportunity Lists 01-14 cleared',
       legacy_cpr_column = 'new_opps_done',
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND item_key = 'opp_lists';

UPDATE public.checklist_items
   SET item_key = 'ecrm_required_fields',
       title = 'Opportunity required fields complete',
       legacy_cpr_column = NULL,
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND item_key = 'ecrm_hygiene';

INSERT INTO public.checklist_items
  (agency_id, item_key, title, scope, sort_order, effective_from, legacy_cpr_column)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365','missing_phone','Missing Phone list cleared','team',72,'2026-09-12','no_phone_done'),
  ('126794dd-25ff-47d2-a436-724499733365','missing_data','Missing Data list cleared','team',74,'2026-09-12','bad_data_done'),
  ('126794dd-25ff-47d2-a436-724499733365','opp_has_task','Every active opportunity has a task','team',82,'2026-09-12','no_fu_task_done'),
  ('126794dd-25ff-47d2-a436-724499733365','ecrm_onboarding_cases','New submitted opportunities have onboarding cases','team',112,'2026-09-12','no_onboarding_done'),
  ('126794dd-25ff-47d2-a436-724499733365','ecrm_cases_closed','Cases closed when no open tasks remain','team',114,'2026-09-12','cases_done')
ON CONFLICT DO NOTHING;