ALTER TABLE public.onboarding_step_templates
  ADD COLUMN IF NOT EXISTS substeps jsonb;

ALTER TABLE public.team_onboarding_steps
  ADD COLUMN IF NOT EXISTS substeps jsonb,
  ADD COLUMN IF NOT EXISTS substeps_done jsonb;

UPDATE public.onboarding_step_templates
SET phase = 1, sort_order = 90
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND template_key = 'p0_door_alarm_codes';

UPDATE public.onboarding_step_templates SET
  title = 'Desk fully set up',
  description = 'Everything working before Day 1.',
  substeps = '["Two monitors","Mouse and keyboard","Dock","Laptop verified","Webcam","Cables tucked","Headset tested on all three audio paths (system, Teams, phone)","Desk supplies staged"]'::jsonb
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_desk_setup';

UPDATE public.onboarding_step_templates SET
  title = 'References requested and received',
  description = '3 professional references. Former managers or supervisors ideal.',
  substeps = '["Reference 1 received","Reference 2 received","Reference 3 received"]'::jsonb
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_references_requested';

UPDATE public.onboarding_step_templates SET
  title = 'Tech setup complete',
  description = 'Day 1. Full step-by-step on the Tech Setup page.',
  substeps = '["Yubikey set up and used to log in","VPN connected (Cisco Secure Client, Yubikey Agency non-California)","Windows Hello set up","Cloud Drive shortcut in place","Taskbar programs pinned","Teams channels pinned","Chrome and Edge bookmarks imported","Outlook signature installed and set as default","Out of office reply set","Outlook contact groups built","Shared directory added","Inbox subfolders and rules created","Recurring meeting invites accepted (Daily Kickoff, SCF Scorecard Review, Weekly Wrap-up)","Jabber speed dials added","LAN printer added","Headset software installed and tested","Report Phishing button present","Photo release accepted in the Electronic Library"]'::jsonb
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p1_tech_setup_page';

UPDATE public.onboarding_step_templates SET
  title = 'Orientation complete',
  description = 'Absorption week. Watch the clips, shadow calls as they come up. Full content on the Orientation page.',
  substeps = '["The Ten — all ten clips watched","Sales Fundamentals — get a no and gap selling clips","Compliance floor understood","Newtworks introduction","SCF Scorecard walkthrough","Ask Ladder — coverage questions and tech problems","Ongoing habits reviewed"]'::jsonb
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p1_orientation_page';

UPDATE public.onboarding_step_templates SET
  title = 'HR paperwork signed and returned',
  description = 'Week 1.',
  substeps = '["W-4","I-9","State Farm Annual Certification","Non-Compete","Payroll and Bio"]'::jsonb
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p1_paperwork_pack';

UPDATE public.onboarding_step_templates SET
  title = 'Workday courses',
  description = 'All five done in Week 1.',
  substeps = '["Info Security and Privacy Training","Anti-Money Laundering — U.S.","Multiline Compliance","Product Overview","Life Insurance Illustrations"]'::jsonb
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p1_workday_courses';

INSERT INTO public.onboarding_step_templates
  (agency_id, template_key, title, description, phase, category,
   applies_to_role_categories, is_required, sort_order, is_active, substeps)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'p1_agent_side_setup',
   'Agent-side setup once paperwork is in',
   'Peter completes these on the new hire''s behalf.',
   1, 'systems', NULL, true, 95, true,
   '["SurePayroll set up and time off applied","Group health enrollment","Photo taken for email signature","Photo release signed","Bio added to the microsite","Electronic Library team member updated","Added to call log reports, Teams groups, Whiteboard, NECHO and hot prospects","Welcome post on agency social"]'::jsonb)
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.create_onboarding_plan_from_templates(p_team_member_id uuid, p_start_date date DEFAULT CURRENT_DATE, p_target_end_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency_id       uuid;
  v_role            text;
  v_role_category   text;
  v_role_level      text;
  v_plan_id         uuid;
  v_step_count      int;
  v_creator_user_id uuid;
BEGIN
  SELECT agency_id, role, role_category, role_level
  INTO v_agency_id, v_role, v_role_category, v_role_level
  FROM public.team
  WHERE id = p_team_member_id;

  IF v_agency_id IS NULL THEN
    RAISE EXCEPTION 'team_member_id % not found', p_team_member_id;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.team_onboarding_plans
    WHERE team_member_id = p_team_member_id
      AND status IN ('active','paused')
  ) THEN
    RAISE EXCEPTION 'Team member % already has an active or paused onboarding plan. Complete or archive it first.', p_team_member_id;
  END IF;

  SELECT id INTO v_creator_user_id
  FROM public.users
  WHERE auth_user_id = auth.uid()
  LIMIT 1;

  INSERT INTO public.team_onboarding_plans (
    agency_id, team_member_id,
    role_snapshot, role_category_snapshot, role_level_snapshot,
    start_date, target_end_date, status, notes, created_by
  ) VALUES (
    v_agency_id, p_team_member_id,
    v_role, v_role_category, v_role_level,
    p_start_date, p_target_end_date, 'active', p_notes, v_creator_user_id
  ) RETURNING id INTO v_plan_id;

  INSERT INTO public.team_onboarding_steps (
    plan_id, template_key, title, description, phase, category,
    source_manual_id, source_anchor, sort_order, is_required,
    substeps, substeps_done
  )
  SELECT
    v_plan_id, t.template_key, t.title, t.description, t.phase, t.category,
    t.source_manual_id, t.source_anchor, t.sort_order, t.is_required,
    t.substeps,
    CASE WHEN t.substeps IS NULL THEN NULL ELSE '[]'::jsonb END
  FROM public.onboarding_step_templates t
  WHERE t.agency_id = v_agency_id
    AND t.is_active = true
    AND (t.applies_to_roles IS NULL OR v_role = ANY (t.applies_to_roles))
    AND (t.applies_to_role_categories IS NULL OR v_role_category = ANY (t.applies_to_role_categories))
    AND (t.applies_to_role_levels IS NULL OR v_role_level = ANY (t.applies_to_role_levels));

  GET DIAGNOSTICS v_step_count = ROW_COUNT;

  IF v_step_count = 0 THEN
    DELETE FROM public.team_onboarding_plans WHERE id = v_plan_id;
    RAISE EXCEPTION 'No matching templates for role=% role_category=% role_level=%. Aborted.',
      v_role, v_role_category, v_role_level;
  END IF;

  RETURN v_plan_id;
END;
$function$;

UPDATE public.team_onboarding_steps s
SET substeps = t.substeps,
    substeps_done = COALESCE(s.substeps_done, '[]'::jsonb)
FROM public.onboarding_step_templates t
WHERE t.template_key = s.template_key
  AND t.substeps IS NOT NULL
  AND s.substeps IS NULL;
