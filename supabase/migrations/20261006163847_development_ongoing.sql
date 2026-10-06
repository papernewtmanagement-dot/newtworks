-- Development > Ongoing. Everything one person has due right now, from three places:
-- their licenses and CE, the handbook, and their part of someone else's onboarding
-- plan. The Ongoing card, the yellow bar and Peter's sidebar counts all read this.
CREATE OR REPLACE FUNCTION public.development_ongoing(p_team_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_t      public.team;
  v_owner  boolean;
  v_tasks  boolean;
  v_mine   text[];
  v_items  jsonb;
BEGIN
  PERFORM public.require_login('staff');
  -- This runs with owner rights, so the check lives here: your own, or an admin.
  IF auth.role() = 'authenticated'
     AND NOT public.is_agency_admin()
     AND p_team_member_id IS DISTINCT FROM public.current_team_member_id() THEN
    RAISE EXCEPTION 'This login cannot see that.' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_t FROM public.team WHERE id = p_team_member_id;
  IF NOT FOUND OR v_t.is_active IS NOT TRUE THEN RETURN '[]'::jsonb; END IF;

  v_owner := EXISTS (SELECT 1 FROM public.users u WHERE u.id = v_t.user_id AND u.role = 'owner');
  -- Peter and Alvi work their onboarding steps from the task list.
  v_tasks := public.user_gets_tasks(v_t.user_id);
  -- How this person is named on a team list: the office name, and the State Farm email name.
  v_mine := array_remove(ARRAY[public.onboarding_team_label(v_t), public.team_sf_email_name(v_t.email_sf)], NULL);

  SELECT COALESCE(jsonb_agg(i ORDER BY (i->>'due') NULLS LAST, i->>'title'), '[]'::jsonb) INTO v_items
  FROM (
    -- Licenses and CE, from the first reminder email (90 days out) until done. The same rows
    -- the license-reminder-runner emails about: active, dated, CE only where CE is required.
    SELECT jsonb_build_object(
             'kind', 'license', 'key', 'license:' || l.id, 'id', l.id,
             'license_type', l.license_type, 'title', l.license_type, 'due', l.due_date,
             'authority', l.authority, 'states', l.states, 'hours_required', l.hours_required,
             'notes', l.notes, 'source_url', l.source_url) AS i
    FROM public.team_licenses l
    WHERE l.team_member_id = p_team_member_id
      AND l.status = 'active'
      AND l.due_date IS NOT NULL
      AND l.due_date <= CURRENT_DATE + 90
      AND NOT ((l.license_type LIKE '%\_ce'
                OR l.license_type IN ('series_6_annual_compliance', 'series_6_regulatory_element'))
               AND l.ce_required IS FALSE)

    UNION ALL
    -- The handbook, while the current version is unconfirmed. Peter wrote it, so never his.
    SELECT jsonb_build_object(
             'kind', 'handbook', 'key', 'handbook', 'title', 'Handbook',
             'line', 'Read the handbook and [confirm](/development?area=forms&form=handbook_ack)',
             'due', v.due_date, 'updated', v.last_completed_at IS NOT NULL)
    FROM public.v_team_form_status v
    WHERE v.team_id = p_team_member_id
      AND v.form_type = 'handbook_ack'
      AND v.state = 'action_needed'
      AND NOT v_owner

    UNION ALL
    -- Their part of someone else's onboarding plan, once that card opens: a team card with
    -- their name still unticked, a card assigned to them or their group, or the references
    -- card when they are the one calling.
    SELECT jsonb_build_object(
             'kind', 'onboarding', 'key', 'step:' || s.id, 'id', s.id, 'plan_id', s.plan_id,
             'title', s.title, 'subject', public.onboarding_plan_subject_name(s.plan_id),
             'due', s.due_on, 'description', s.description,
             'substeps', s.substeps, 'substeps_done', s.substeps_done,
             'substep_answers', s.substep_answers, 'completed_at', s.completed_at,
             'auto_source', s.auto_source, 'candidate_id', p.candidate_id,
             'mine', CASE WHEN s.owner_kind = 'team' THEN to_jsonb(ARRAY(
                       SELECT DISTINCT l FROM unnest(public.onboarding_substep_labels(s.substeps)) l
                       WHERE l = ANY (v_mine)
                         AND NOT (CASE WHEN jsonb_typeof(s.substeps_done) = 'array'
                                       THEN s.substeps_done ? l ELSE false END))) END)
    FROM public.team_onboarding_steps s
    JOIN public.team_onboarding_plans p ON p.id = s.plan_id
    WHERE NOT v_tasks
      AND p.agency_id = v_t.agency_id
      AND p.team_member_id IS DISTINCT FROM p_team_member_id
      AND s.completed_at IS NULL
      AND (
            (s.owner_kind = 'team' AND EXISTS (
               SELECT 1 FROM unnest(public.onboarding_substep_labels(s.substeps)) l
               WHERE l = ANY (v_mine)
                 AND NOT (CASE WHEN jsonb_typeof(s.substeps_done) = 'array'
                               THEN s.substeps_done ? l ELSE false END)))
         OR s.assigned_to = p_team_member_id
         OR (s.assign_role_category IS NOT NULL AND s.assign_role_category = v_t.role_category)
         OR (s.auto_source = 'references' AND p.candidate_id IS NOT NULL AND EXISTS (
               SELECT 1 FROM public.hiring_reference_callers(p.candidate_id) k
               WHERE k.team_member_id = p_team_member_id))
          )
      AND public.onboarding_step_is_open(s.id)
  ) x;

  RETURN v_items;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.development_ongoing(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.development_ongoing(uuid) TO authenticated, service_role;

-- How many things each active teammate has in Ongoing. Admin sidebar only.
CREATE OR REPLACE FUNCTION public.development_ongoing_counts()
 RETURNS TABLE(team_member_id uuid, items integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.require_login('admin');
  RETURN QUERY
    SELECT t.id, jsonb_array_length(public.development_ongoing(t.id))
    FROM public.team t
    WHERE t.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
      AND t.is_active IS TRUE
      AND COALESCE(t.is_test_user, false) = false;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.development_ongoing_counts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.development_ongoing_counts() TO authenticated, service_role;

