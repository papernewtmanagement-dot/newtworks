-- Columns within a phase (track) and gating between steps (blocked_by).
ALTER TABLE public.onboarding_step_templates
  ADD COLUMN IF NOT EXISTS track      text,
  ADD COLUMN IF NOT EXISTS blocked_by text[];

ALTER TABLE public.team_onboarding_steps
  ADD COLUMN IF NOT EXISTS track      text,
  ADD COLUMN IF NOT EXISTS blocked_by text[];

-- Phase 15 folds into phase 10 as its second column.
UPDATE public.onboarding_phases SET is_active = false
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND phase IN (15, 30);

UPDATE public.onboarding_phases
SET name = 'On offer', blurb = 'Both columns have to finish before we can request the alias.'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND phase = 10;

UPDATE public.onboarding_phases
SET name = 'Access requested', blurb = 'Once both offer columns are done.'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND phase = 20;

UPDATE public.onboarding_phases
SET name = 'Once the alias is in', blurb = 'Alvi orders equipment and sets up the phone.'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND phase = 25;

UPDATE public.onboarding_phases
SET blurb = 'Desk built and checked once the equipment lands.'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND phase = 35;

-- ── Retire the steps Peter called out ───────────────────────────────
UPDATE public.onboarding_step_templates SET is_active = false
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND template_key IN (
    't_offer_email',          -- goes out automatically at the offer stage
    't_licensing_path',       -- the candidate owns this, we just send it
    't_system_access',        -- same thing as the ECRM step
    't_team_list',            -- Newtworks adds them when Peter does
    't_workspace_confirmed',  -- same thing as the desk checklist
    'p0_welcome_text',        -- same thing as the Friday call or text
    'p0_first_week_schedule'  -- that is this checklist
  );

-- ── Phase 10, column one: offer, licenses, personal info ────────────
UPDATE public.onboarding_step_templates
SET phase = 10, track = 'Offer and licensing', sort_order = 10, blocked_by = NULL
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_offer_signed';

UPDATE public.onboarding_step_templates
SET phase = 10, track = 'Offer and licensing', sort_order = 20,
    blocked_by = ARRAY['p0_offer_signed']
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_prior_appts_terminated';

UPDATE public.onboarding_step_templates SET
  title = 'Both licenses on file',
  description = 'The end of the licensing process. They run it, we confirm we have each one.',
  phase = 10, track = 'Offer and licensing', sort_order = 30,
  blocked_by = ARRAY['p0_offer_signed'],
  substeps = '["Property and Casualty license on file","Life and Health license on file"]'::jsonb
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_pc_license';

UPDATE public.onboarding_step_templates SET
  phase = 10, track = 'Offer and licensing', sort_order = 40,
  blocked_by = ARRAY['p0_pc_license']
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_personal_info';

-- ── Phase 10, column two: the checks ────────────────────────────────
UPDATE public.onboarding_step_templates
SET phase = 10, track = 'Checks', sort_order = 10
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_references_requested';

UPDATE public.onboarding_step_templates
SET phase = 10, track = 'Checks', sort_order = 20
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_background_check';

-- ── Phase 20: the access request, gated on both columns ─────────────
UPDATE public.onboarding_step_templates SET
  title = 'System Access Request submitted',
  description = 'ABS to Office Admin to Team Resources. Needs Social Security number, date of birth, languages, skill level. Creates the ECRM account and the alias. VPN comes with it.',
  phase = 20, track = NULL, sort_order = 10,
  blocked_by = ARRAY['p0_pc_license','t_personal_info','p0_references_requested','t_background_check']
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_ecrm_account';

UPDATE public.onboarding_step_templates SET
  phase = 20, track = NULL, sort_order = 20,
  blocked_by = ARRAY['p0_ecrm_account'],
  description = 'Done at the same time as the access request. Adding them here also puts them on the team list.'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_newtworks_login';

-- ── Phase 25: Alvi, once the alias exists ───────────────────────────
UPDATE public.onboarding_step_templates SET
  title = 'Order equipment',
  phase = 25, sort_order = 10,
  blocked_by = ARRAY['p0_ecrm_account'],
  substeps = '["Equipment ordered","One extra laptop confirmed after accounting for the new hire","Yubikey ordered"]'::jsonb
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_order_equipment';

UPDATE public.onboarding_step_templates SET
  phase = 25, sort_order = 20,
  owner_kind = 'admin', assigned_to = 'd7431075-d29f-4833-9503-430945894b04',
  blocked_by = ARRAY['p0_ecrm_account']
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_softphone';

UPDATE public.onboarding_step_templates SET
  phase = 25, sort_order = 30,
  owner_kind = 'admin', assigned_to = 'd7431075-d29f-4833-9503-430945894b04',
  description = 'Done with the softphone. Agent Telephony Request. Broadcast, top-down or auto-attendant per the call flow reference.',
  blocked_by = ARRAY['t_softphone']
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_call_flow';

-- ── Phase 35: desk checklist, waits on the equipment ────────────────
UPDATE public.onboarding_step_templates SET
  description = 'Built and confirmed working once the equipment lands.',
  phase = 35, sort_order = 10,
  blocked_by = ARRAY['t_order_equipment'],
  substeps = '[
    {"group":"Computing hardware","items":["Monitors x 2","Wireless mouse","Keyboard","Dock","Laptop","Laptop verified as working","Webcam","All cables organized and tucked away"]},
    {"group":"Yubikey","items":["Yubikey received","Yubikey set up on Peter''s computer (PIN 3276)","New hire logs in with the Yubikey"]},
    {"group":"Headset","items":["Headset with charging dock","Tested on system audio","Tested on Teams","Tested on a phone call"]},
    {"group":"Desk supplies","items":["Pen cup","Branded pens x 5","Kleenex","Business card holder","Vertical file organizer"]},
    {"group":"Remote or travel bag (remote hires)","items":["Laptop bag","Laptop charging cable","Wired headset","Mouse"]}
  ]'::jsonb
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_desk_setup';

-- ── Physical access and cards move past the first weeks ─────────────
UPDATE public.onboarding_step_templates SET
  phase = 60, sort_order = 5,
  description = 'Once their first week is behind them.',
  owner_kind = 'admin', assigned_to = 'd7431075-d29f-4833-9503-430945894b04'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_spare_door_key';

UPDATE public.onboarding_step_templates SET
  phase = 60, sort_order = 6,
  description = 'Once their first week is behind them.'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_door_alarm_codes';

INSERT INTO public.onboarding_step_templates
  (agency_id, template_key, title, description, phase, category,
   owner_kind, assigned_to, is_required, sort_order, is_active)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365','t_business_cards','Order business cards',
   'Once their fourth week is complete and going well.',
   65,'physical_setup','admin','d7431075-d29f-4833-9503-430945894b04',true,5,true)
ON CONFLICT DO NOTHING;
