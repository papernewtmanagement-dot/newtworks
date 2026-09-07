-- Bring the last unrepresented items from the old admin "Onboarding Schedule"
-- page into onboarding_step_templates, so the page can be retired.
-- Everything else on that page was already covered by the template library or
-- already lives in the Handbook (Code Red grace table, weekly quote targets).

INSERT INTO public.onboarding_step_templates
  (agency_id, template_key, title, description, phase, category,
   applies_to_role_categories, is_required, sort_order, is_active)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'p1_linkedin_social',
   'Update LinkedIn and personal social to show place of work',
   'Week 1. Profile and personal accounts reflect the agency.',
   1, 'training', NULL, true, 80, true),

  ('126794dd-25ff-47d2-a436-724499733365', 'p1_ret_pivot_roleplay',
   'Daily Simple Reception Pivot role-play — 15 min',
   'Weeks 1-4, every day, with Peter or a senior Account Manager.',
   1, 'training', ARRAY['Retention'], true, 140, true),

  ('126794dd-25ff-47d2-a436-724499733365', 'p1_sales_stairs_buckets',
   'Watch Stairs & Buckets (about 15 min)',
   'Week 1 viewing before the Life FIT role-plays start.',
   1, 'training', ARRAY['Sales'], true, 140, true),

  ('126794dd-25ff-47d2-a436-724499733365', 'p1_sales_life_fit_roleplay',
   'Daily Simple Life FIT role-play with a senior Account Manager — 15 min',
   'Weeks 1-13, every day.',
   1, 'training', ARRAY['Sales'], true, 150, true),

  ('126794dd-25ff-47d2-a436-724499733365', 'p1_sales_auto_gnc_roleplay',
   'Daily Auto Lead Process — Through GNC role-play — 15 min',
   'Weeks 1-13, every day.',
   1, 'training', ARRAY['Sales'], true, 160, true)
ON CONFLICT DO NOTHING;

-- The old page carried the two State Farm setup links; the step did not.
UPDATE public.onboarding_step_templates
SET description = 'Week 14 and later. Only agency-owned devices are allowed. '
  || 'Setup steps: https://sfnet.opr.statefarm.org/agency/manuals/technology/agency_mobile_setup_maintenance/blackberry_work_activate_setup.shtml '
  || '— Activation key: https://sfnet.opr.statefarm.org/agency/manuals/technology/agency_mobile_setup_maintenance/get_new_act_key.shtml'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND template_key = 'p5_remote_device_form';
