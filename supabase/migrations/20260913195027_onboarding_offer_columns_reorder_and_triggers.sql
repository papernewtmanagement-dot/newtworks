-- Column order is data now, so the right-hand column stays on the right.
ALTER TABLE public.onboarding_step_templates
  ADD COLUMN IF NOT EXISTS track_order int NOT NULL DEFAULT 0;
ALTER TABLE public.team_onboarding_steps
  ADD COLUMN IF NOT EXISTS track_order int NOT NULL DEFAULT 0;

-- Left column: offer, the checks, licensing, personal info.
UPDATE public.onboarding_step_templates
SET track = 'Offer, checks and licensing', track_order = 1
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND template_key IN ('p0_offer_signed','p0_references_requested','t_background_check',
                       'p0_pc_license','p0_prior_appts_terminated','t_personal_info');

UPDATE public.onboarding_step_templates SET sort_order = 10, blocked_by = NULL
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_offer_signed';

UPDATE public.onboarding_step_templates SET sort_order = 20, blocked_by = ARRAY['p0_offer_signed']
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_references_requested';

UPDATE public.onboarding_step_templates SET sort_order = 30, blocked_by = ARRAY['p0_references_requested']
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_background_check';

UPDATE public.onboarding_step_templates SET sort_order = 40, blocked_by = ARRAY['p0_offer_signed']
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_prior_appts_terminated';

UPDATE public.onboarding_step_templates SET sort_order = 50, blocked_by = ARRAY['p0_offer_signed']
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_pc_license';

UPDATE public.onboarding_step_templates SET sort_order = 60, blocked_by = ARRAY['p0_pc_license']
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_personal_info';

-- Right column: equipment on top, desk checklist under it.
UPDATE public.onboarding_step_templates
SET phase = 10, track = 'Workspace', track_order = 2, sort_order = 10,
    blocked_by = ARRAY['p0_references_requested']
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_order_equipment';

UPDATE public.onboarding_step_templates
SET phase = 10, track = 'Workspace', track_order = 2, sort_order = 20,
    blocked_by = ARRAY['t_order_equipment']
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_desk_setup';

-- The softphone no longer waits on the equipment order being in the same phase.
UPDATE public.onboarding_step_templates
SET blocked_by = ARRAY['p0_ecrm_account']
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_softphone';

-- Friday text, written out so it is not reinvented every time.
UPDATE public.onboarding_step_templates SET
  title = 'Friday text before the start date',
  description = E'Send this, filling in the name:\n\n"Hi [name] — really looking forward to kicking things off with you Monday. Plan to be here by 8:30. Bring your driver license and Social Security card and that is all you need. Text me here if anything comes up over the weekend."\n\nFully remote hires get the remote welcome email instead.',
  substeps = NULL
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_friday_call';