UPDATE public.onboarding_step_templates SET phase = CASE phase
    WHEN 2 THEN 60 WHEN 3 THEN 65 WHEN 4 THEN 70 WHEN 5 THEN 75 ELSE phase END
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND phase IN (2,3,4,5);

UPDATE public.onboarding_step_templates SET phase = 50
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND template_key IN ('p1_tech_setup_page','p1_paperwork_pack','p0_door_alarm_codes');

UPDATE public.onboarding_step_templates SET phase = 55
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND phase = 1;

UPDATE public.onboarding_step_templates SET phase = 10
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND template_key IN ('p0_offer_signed','p0_pc_license','p0_prior_appts_terminated');

UPDATE public.onboarding_step_templates SET phase = 15
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_references_requested';

UPDATE public.onboarding_step_templates SET phase = 20
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_ecrm_account';

UPDATE public.onboarding_step_templates SET phase = 25
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_newtworks_login';

UPDATE public.onboarding_step_templates SET phase = 35
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_desk_setup';

UPDATE public.onboarding_step_templates SET phase = 40
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND template_key IN ('p0_welcome_text','p0_first_week_schedule');

UPDATE public.onboarding_step_templates SET is_active = false
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_yubikey_ordered';

UPDATE public.onboarding_step_templates SET owner_kind = 'agent'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND template_key IN ('p0_welcome_text','p0_first_week_schedule','p0_ecrm_account',
                       'p0_newtworks_login','p0_references_requested','p1_agent_side_setup');

UPDATE public.onboarding_step_templates
SET owner_kind = 'admin', assigned_to = 'd7431075-d29f-4833-9503-430945894b04'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND template_key IN ('p0_desk_setup','p0_door_alarm_codes');

UPDATE public.onboarding_step_templates SET
  title = 'Desk checklist',
  description = 'Every item in place and working before Day 1.',
  category = 'physical_setup',
  substeps = '[
    {"group":"Computing hardware","items":["Monitors x 2","Wireless mouse","Keyboard","Dock","Laptop","Laptop verified as working","Webcam","All cables organized and tucked away"]},
    {"group":"Yubikey","items":["Yubikey received","In-office: Yubikey set up on Peter''s computer, then used to log in"]},
    {"group":"Headset","items":["Headset with charging dock","Tested on system audio","Tested on Teams","Tested on a phone call"]},
    {"group":"Desk supplies","items":["Pen cup","Branded pens x 5","Kleenex","Business card holder","Vertical file organizer"]},
    {"group":"Remote or travel bag (remote hires)","items":["Laptop bag","Laptop charging cable","Wired headset","Mouse"]}
  ]'::jsonb
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_desk_setup';

UPDATE public.onboarding_step_templates SET
  title = 'Tech setup',
  description = 'Day 1, in this order. Full step-by-step on the Tech Setup page.',
  substeps = '[
    {"group":"Login and hardware","items":["Login sheet in hand","Yubikey setup sheet in hand","Yubikey set up on Peter''s computer","Logged in to the computer with the Yubikey"]},
    {"group":"VPN and Windows","items":["Cisco Secure Client connected on Yubikey Agency (non California)","Windows Hello for Business set up","Cloud Drive shortcut in place"]},
    {"group":"Pins","items":["Taskbar programs pinned","Teams channels pinned under Office","Teams channels pinned under Personal Offices"]},
    {"group":"Browsers","items":["Chrome bookmarks imported","Edge favorites imported and favorites bar always on"]},
    {"group":"Outlook","items":["Signature installed and set as default for new and reply","Out of office reply set","Contact groups built","Shared directory added","Preview no longer marks mail read","Inbox subfolders and rules created","Recurring invites accepted: Daily Kickoff, SCF Scorecard Review, Weekly Wrap-up"]},
    {"group":"Phone and devices","items":["Jabber speed dials added","LAN printer A532561PCL01 added","Plantronics Hub installed and headset settings adjusted"]},
    {"group":"Last checks","items":["Report Phishing button present in Outlook","Photo release accepted in the Electronic Library"]}
  ]'::jsonb
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p1_tech_setup_page';

UPDATE public.onboarding_step_templates SET
  title = 'References requested and checked',
  description = '3 professional references, former managers or supervisors ideal.',
  substeps = '["Reference 1 checked","Reference 2 checked","Reference 3 checked"]'::jsonb
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_references_requested';

INSERT INTO public.onboarding_step_templates
  (agency_id, template_key, title, description, phase, category,
   owner_kind, assigned_to, is_required, sort_order, is_active, substeps)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365','t_offer_email','Send the Reference Check and Next Steps email',
   'Verbatim template on the Admin Setup page. Fill in name and salary.',
   10,'documents','agent',NULL,true,5,true,NULL),

  ('126794dd-25ff-47d2-a436-724499733365','t_personal_info','Collect Social Security number, date of birth and address',
   'Needed for the system access request. Ask for a good time to call.',
   10,'documents','agent',NULL,true,15,true,NULL),

  ('126794dd-25ff-47d2-a436-724499733365','t_licensing_path','Get licensed — exam, fingerprints, license application',
   'Agency reimburses $189 total for both lines. Partner code APSTORY on Xcel. EIN for the application: 831295615.',
   10,'licensing','new_hire',NULL,true,25,true,
   '[
     {"group":"Schedule the exam","items":["Create a PearsonVue account","Select General Lines Property and Casualty","Select General Lines Life and Health","Pick a test center and lock in a date"]},
     {"group":"Study","items":["Enroll at Xcel Solutions with partner code APSTORY","Select state, Get License, and both lines of authority","Take the $189 package"]},
     {"group":"Take the exam","items":["Property and Casualty passed","Life and Health passed"]},
     {"group":"Fingerprints","items":["Identogo: Get Fingerprinted, Texas, Digital Fingerprinting","Department of Insurance code 11G6QF entered","Code from the exam results page entered"]},
     {"group":"Apply","items":["Sircon: new resident individual insurance license","EIN 831295615 entered","Texas license applied for if resident state is not Texas"]},
     {"group":"Plan ahead","items":["Calendar reminder set for the continuing education deadline"]}
   ]'::jsonb),

  ('126794dd-25ff-47d2-a436-724499733365','t_background_check','Background check',
   'Runs when they reply to the offer email.',
   15,'documents','agent',NULL,true,20,true,
   '["Background check sent through BIG","Background check reviewed","Onboarding Form submitted with Autopilot"]'::jsonb),

  ('126794dd-25ff-47d2-a436-724499733365','t_system_access','Submit the Agent Team Member System Access Request',
   'ABS to Office Admin to Team Resources. Needs Social Security number, date of birth, languages, skill level. VPN comes with it now.',
   20,'systems','agent',NULL,true,5,true,NULL),

  ('126794dd-25ff-47d2-a436-724499733365','t_order_equipment','Order equipment and cards',
   'Agent Activity Order form under ABS Forms.',
   20,'physical_setup','admin','d7431075-d29f-4833-9503-430945894b04',true,15,true,
   '["Equipment ordered","One extra laptop confirmed after accounting for the new hire","Yubikey ordered","Business cards ordered","Desk nameplate ordered (in-office hires)"]'::jsonb),

  ('126794dd-25ff-47d2-a436-724499733365','t_softphone','Set up the softphone',
   'Agent Telephony Request, Add Softphone or Create New Phone Extension, look up the alias.',
   25,'systems','agent',NULL,true,5,true,NULL),

  ('126794dd-25ff-47d2-a436-724499733365','t_team_list','Add them to the Team List',
   'Personal phone, email, address.',
   30,'systems','agent',NULL,true,5,true,NULL),

  ('126794dd-25ff-47d2-a436-724499733365','t_call_flow','Change the call flow',
   'Agent Telephony Request. Broadcast, top-down or auto-attendant per the call flow reference.',
   30,'systems','agent',NULL,true,15,true,NULL),

  ('126794dd-25ff-47d2-a436-724499733365','t_spare_door_key','Spare door key ready for Day 1 handoff',
   'In-office hires only.',
   35,'physical_setup','admin','d7431075-d29f-4833-9503-430945894b04',false,15,true,NULL),

  ('126794dd-25ff-47d2-a436-724499733365','t_workspace_confirmed','Confirm the workspace',
   'In-office: desk checklist verified. Fully remote: Yubikey plus VPN access confirmed.',
   35,'physical_setup','agent',NULL,true,25,true,NULL),

  ('126794dd-25ff-47d2-a436-724499733365','t_friday_call','Friday call or text before the start date',
   'Looking forward to kicking things off. Arrive by 8:30 Monday with driver license and Social Security card. Fully remote hires get the remote welcome email instead.',
   40,'documents','agent',NULL,true,5,true,NULL),

  ('126794dd-25ff-47d2-a436-724499733365','t_print_packet','Print the Day 1 packet',
   'Skip for former State Farm hires and fully remote hires — they call 1-877-889-2294 with their alias and Peter joins to verify employment.',
   40,'documents','agent',NULL,true,25,true,
   '["Login Packet printed (temp password changes on each print)","New Hire Documents printed","Yubikey Setup, Windows Hello and Training Schedule printouts","Annual Certification Form printed"]'::jsonb)
ON CONFLICT DO NOTHING;
