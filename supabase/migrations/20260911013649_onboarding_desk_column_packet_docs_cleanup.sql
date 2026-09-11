-- Desk checklist becomes the third column of the offer stage. It still waits on
-- the equipment order, so the trigger does the sequencing, not the placement.
UPDATE public.onboarding_step_templates
SET phase = 10, track = 'Workspace', sort_order = 10
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_desk_setup';

UPDATE public.onboarding_step_templates
SET track = 'Offer and licensing'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND phase = 10 AND track IS NULL;

UPDATE public.onboarding_phases SET is_active = false
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND phase = 35;

-- The packet is the Login Packet plus the New Hire Documents. The Yubikey,
-- Windows Hello and computer-setup sheets are Newtworks pages, not printouts.
UPDATE public.onboarding_step_templates SET
  title = 'Print the Day 1 packet',
  description = 'Login Packet: ABS, Agent Admin, Team Resources, Staff Setup & Registration. The temporary password changes every time it prints. Former State Farm and fully remote hires get no packet — they call 1-877-889-2294 with their alias and Peter joins to verify employment.',
  substeps = '[
    {"group":"Login Packet","items":["Login Packet printed"]},
    {"group":"New Hire Documents","items":["W-4","I-9","State Farm Annual Certification","Non-Compete","Payroll and Bio"]}
  ]'::jsonb
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_print_packet';

UPDATE public.onboarding_step_templates SET
  description = 'Week 1. Same documents that were printed in the Friday packet.'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p1_paperwork_pack';

-- Invented step. Nothing like this exists.
UPDATE public.onboarding_step_templates SET is_active = false
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p1_compliance_ack';
