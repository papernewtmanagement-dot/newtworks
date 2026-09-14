-- Everything the old pages carried that the module did not: the clip links,
-- the call flow form, and the Annual Certification path.
UPDATE public.onboarding_step_templates SET
  title = 'Orientation complete',
  description = 'Absorption week. Watch the clips, shadow calls as they come up.',
  substeps = '[
    {"group":"The Ten","items":[
      "1. Scripture as the frame — Know Your Why: https://www.facebook.com/share/v/oPaXS7zcYNHTZEUs/?mibextid=w8EBqM",
      "2. Who we are",
      "3. Foundation of ethics",
      "4. Eat the elephant: https://youtu.be/LZpAYmUpx44?si=2oKB3Wthv-Tcvk-m",
      "4. 20-mile march (Jim Collins): https://www.c-span.org/clip/news-conference/user-clip-20-mile-march-jim-collins/5067394",
      "5. Put the big rocks first: https://www.youtube.com/watch?v=WG7R6XodW18",
      "5. 4 Disciplines of Execution: https://www.youtube.com/watch?v=mP7sq_tGZj8",
      "6. Super Mario Effect (Mark Rober TEDxPenn): https://www.facebook.com/GrowthTribeIO/videos/the-super-mario-effect-mark-rober-tedxpenn/3742136095839571/",
      "6. Failure reframe clip 1: https://www.youtube.com/watch?v=xKd3MD4n6ng",
      "6. Failure reframe clip 2: https://www.youtube.com/watch?v=pTKfaVzbpJ4",
      "7. Volume negates luck: https://www.youtube.com/shorts/fDm1KLlQ4wM",
      "8. Weekly goals math",
      "9. Health goals",
      "10. 10-to-1 rule, Bug me, and Kipling''s If"]},
    {"group":"The Ten #1 homework","items":["Type out your why and send it to Peter"]},
    {"group":"Sales Fundamentals — get a no and gap selling","items":[
      "Rejection Therapy (start at 4:20): https://www.youtube.com/watch?v=ZFWyseydTkQ",
      "Set no goals: https://www.youtube.com/watch?v=SMiJeU7nU7k",
      "Don''t stop until you get a no (funny sale until 2:59): https://www.youtube.com/watch?v=UZTKFJ-xipw",
      "Learn to get a no #1: https://www.youtube.com/watch?v=waTzPF4P6oY",
      "Learn to get a no #2 (watch until 4:12): https://www.youtube.com/watch?v=hjrmd-TSmbc",
      "Tactical empathy: https://www.youtube.com/watch?v=QIRk382yJm4",
      "Yes and (TikTok): https://www.tiktok.com/@askvinh/video/7415565490170449173",
      "Yes and (YouTube Short): https://www.youtube.com/shorts/il48SeduYOY"]},
    {"group":"The rest of orientation","items":[
      "Compliance floor",
      "Newtworks introduction",
      "SCF Scorecard walkthrough",
      "Ask Ladder — coverage questions and tech problems",
      "Ongoing habits"]}
  ]'::jsonb
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p1_orientation_page';

-- The homework had its own step; it is inside orientation now.
UPDATE public.onboarding_step_templates SET is_active = false
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p1_ten_why';

UPDATE public.onboarding_step_templates SET
  description = 'Done with the softphone. ABS, Agent Telephony Request: https://notesforms001.opr.statefarm.org/sff/agent/w0058420.nsf/postform?CreateDocument&back&sffid=155795 — broadcast, top-down or auto-attendant per the call flow reference.'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_call_flow';

UPDATE public.onboarding_step_templates SET
  substeps = '[
    {"group":"Login Packet","items":["Login Packet printed — ABS, Agent Admin, Team Resources, Staff Setup & Registration"]},
    {"group":"New Hire Documents","items":[
      "W-4 — https://www.irs.gov/pub/irs-pdf/fw4.pdf",
      "I-9 — https://www.uscis.gov/sites/default/files/document/forms/i-9.pdf",
      "State Farm Annual Certification — ABS, Office Admin, Compliance, Annual Certification Form",
      "Non-Compete",
      "Payroll and Bio"]}
  ]'::jsonb
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_print_packet';

UPDATE public.onboarding_step_templates SET
  substeps = '[
    "W-4 — https://www.irs.gov/pub/irs-pdf/fw4.pdf",
    "I-9 — https://www.uscis.gov/sites/default/files/document/forms/i-9.pdf",
    "State Farm Annual Certification",
    "Non-Compete",
    "Payroll and Bio"]'::jsonb
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p1_paperwork_pack';

-- Licensing deadline is the end of week 13, not "week 14".
UPDATE public.onboarding_step_templates SET
  title = 'Licenses verified as active',
  description = 'Anyone who started unlicensed is licensed by the end of week 13.'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p5_pc_licensed_verified';