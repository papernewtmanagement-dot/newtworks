-- Shorter, front-loaded checklist titles. First 30 characters must stand alone,
-- because the kickoff Telegram truncates to 30 + ellipsis (Peter 2026-09-15).
-- Also regroups sort_order into coherent blocks.

-- ===== TEAM: inbound and requests =====
UPDATE public.checklist_items SET title='Shared Outlook folders cleared', sort_order=10,
  help_text=COALESCE(help_text, 'The * and @ shared folders in Outlook. Both worked down to empty by end of day.')
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='shared_folders';

UPDATE public.checklist_items SET title='Texts handled', sort_order=20
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='texts';

UPDATE public.checklist_items SET title='Incoming mail handled', sort_order=30
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='mail';

UPDATE public.checklist_items SET title='Do Not Call list cleared', sort_order=40
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='dnc';

UPDATE public.checklist_items SET title='Appointments checked, reminded', sort_order=50,
  help_text=COALESCE(help_text, 'Verify every upcoming appointment is still on, and send the reminder.')
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='appointments';

-- ===== TEAM: sales pipeline =====
UPDATE public.checklist_items SET title='Opportunity Lists 01-14 cleared', sort_order=60
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='opp_lists';

UPDATE public.checklist_items SET title='Missing Phone list cleared', sort_order=70
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='missing_phone';

UPDATE public.checklist_items SET title='Missing Data list cleared', sort_order=80
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='missing_data';

UPDATE public.checklist_items SET title='Every opportunity has a task', sort_order=90
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='opp_has_task';

UPDATE public.checklist_items SET title='Sales tasks completed', sort_order=100
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='sales_tasks';

UPDATE public.checklist_items SET title='10 campaign leads converted', sort_order=110,
  help_text=COALESCE(help_text, '') || E'\n\n10 per sales team member, every day.'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='campaign_leads';

-- ===== TEAM: service, cases, retention =====
UPDATE public.checklist_items SET title='Billed-prior-month campaign', sort_order=120
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='billed_prior_month';

UPDATE public.checklist_items SET title='Onboarding cases created', sort_order=130
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='ecrm_onboarding_cases';

UPDATE public.checklist_items SET title='Cases with no tasks closed', sort_order=140
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='ecrm_cases_closed';

UPDATE public.checklist_items SET title='Service tasks worked or pended', sort_order=150
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='service_tasks';

-- ===== TEAM: close of day =====
UPDATE public.checklist_items SET title='Production Manager, after 4 PM', sort_order=160
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='production_manager';

UPDATE public.checklist_items SET title='Final deposit + Close Day', sort_order=170
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='deposits';

UPDATE public.checklist_items SET title='Office out-of-office text set', sort_order=180
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='ooo_text_office';

-- ===== PERSONAL =====
UPDATE public.checklist_items SET title='Inbox cleared', sort_order=10
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='inbox';

UPDATE public.checklist_items SET title='Conversations logged in ECRM', sort_order=20
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='ecrm_accurate';

UPDATE public.checklist_items SET title='Activity logged on Dashboard', sort_order=30
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='whiteboard';

UPDATE public.checklist_items SET title='Out-of-office email set', sort_order=40
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='ooo';
