-- Orientation as a checklist (Peter 2026-10-05).
-- Peter ticks the orientation script line by line for the hires in the room. Each hire's
-- ticks live on their plan. Videos left unticked in a section he finished go on the hire's
-- Watch card for the week; a section he didn't finish keeps its videos for later.

ALTER TABLE public.team_onboarding_plans
  ADD COLUMN IF NOT EXISTS orientation_checked jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS orientation_videos  jsonb NOT NULL DEFAULT '[]'::jsonb;

COMMENT ON COLUMN public.team_onboarding_plans.orientation_checked IS
  'Orientation script lines Peter has covered with this hire, as the line text. Written by the orientation pop-up.';
COMMENT ON COLUMN public.team_onboarding_plans.orientation_videos IS
  'Orientation videos owed from sections Peter finished: [{label, week}]. onboarding_templates_for_plan() puts them on that week''s Watch card under From Orientation. Written only by onboarding_orientation_videos().';

-- The Watch card for a week carries the orientation videos owed for that week, as a
-- From Orientation group after its own lines. Everything else is unchanged.
CREATE OR REPLACE FUNCTION public.onboarding_templates_for_plan(p_plan_id uuid)
 RETURNS SETOF onboarding_step_templates
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- The row build sits in a LATERAL join on purpose. Written as (jsonb_populate_record(...)).*
  -- in the select list, Postgres runs it once per column instead of once per row.
  -- Orientation videos owed for a week (team_onboarding_plans.orientation_videos) are added
  -- to that week's Watch card as a From Orientation group.
  SELECT r.*
  FROM public.team_onboarding_plans p
  JOIN public.onboarding_step_templates t
    ON t.agency_id = p.agency_id
   AND t.is_active = true
   AND (t.applies_to_roles           IS NULL OR p.role_snapshot          = ANY (t.applies_to_roles))
   AND (t.applies_to_role_categories IS NULL OR p.role_category_snapshot = ANY (t.applies_to_role_categories))
   AND (t.applies_to_role_levels     IS NULL OR p.role_level_snapshot    = ANY (t.applies_to_role_levels))
  LEFT JOIN public.onboarding_phases ph
    ON ph.agency_id = p.agency_id AND ph.phase = t.phase AND ph.stage = 'ramp' AND COALESCE(ph.weeks_long, 0) >= 1
  LEFT JOIN LATERAL (
    SELECT gs AS n
    FROM generate_series(public.onboarding_phase_first_week(p.agency_id, t.phase),
                         public.onboarding_phase_first_week(p.agency_id, t.phase) + ph.weeks_long - 1) gs
    WHERE ph.phase IS NOT NULL AND (t.weeks IS NULL OR gs = ANY (t.weeks))
  ) w ON true
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(v.e ->> 'label' ORDER BY v.ord) AS items
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p.orientation_videos) = 'array'
                                   THEN p.orientation_videos ELSE '[]'::jsonb END) WITH ORDINALITY AS v(e, ord)
    WHERE t.title = 'Watch' AND w.n IS NOT NULL
      AND COALESCE(v.e ->> 'label', '') <> ''
      AND CASE WHEN (v.e ->> 'week') ~ '^\d+$' THEN (v.e ->> 'week')::int END = w.n
  ) ov ON true
  CROSS JOIN LATERAL jsonb_populate_record(NULL::public.onboarding_step_templates,
            to_jsonb(t) || jsonb_build_object(
              'template_key', CASE WHEN ph.weeks_long > 1 THEN t.template_key || '@w' || w.n ELSE t.template_key END,
              'plan_week_no', w.n,
              'plan_unlocks_on', COALESCE(
                 public.onboarding_unlock_date(t.unlock_rule, p.start_date),
                 CASE WHEN w.n IS NOT NULL AND p.start_date IS NOT NULL
                      THEN public.onboarding_phase_opens_on(p.agency_id, t.phase, p.start_date)
                           + 7 * (w.n - public.onboarding_phase_first_week(p.agency_id, t.phase)) END))
            || CASE WHEN ov.items IS NULL THEN '{}'::jsonb
                    ELSE jsonb_build_object('substeps',
                           (CASE WHEN jsonb_typeof(t.substeps) = 'array' THEN t.substeps ELSE '[]'::jsonb END)
                           || jsonb_build_array(jsonb_build_object('group', 'From Orientation', 'items', ov.items))) END) r
  WHERE p.id = p_plan_id
    AND (ph.phase IS NULL OR w.n IS NOT NULL);
$function$;

-- The one place orientation videos are assigned. p_videos is the full list the hire still
-- owes from sections Peter finished (the pop-up works it out from the script). A video
-- already listed keeps its week. One no longer owed comes off, unless the hire already
-- ticked it on the card. A new one goes on the Watch card of the week the hire is in now
-- (the latest Watch card that has opened, or the first one before the start date).
CREATE OR REPLACE FUNCTION public.onboarding_orientation_videos(p_plan_id uuid, p_videos text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_plan  record;
  v_week  int;
  v_next  jsonb;
  v_sync  jsonb;
BEGIN
  IF COALESCE(public.current_app_user_role(), '') <> 'owner' THEN
    RAISE EXCEPTION 'Peter runs orientation.';
  END IF;

  SELECT * INTO v_plan
  FROM public.team_onboarding_plans
  WHERE id = p_plan_id
    AND agency_id = (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Onboarding plan % not found.', p_plan_id;
  END IF;

  SELECT COALESCE(max(s.week_no) FILTER (WHERE s.unlocks_on IS NULL OR s.unlocks_on <= CURRENT_DATE),
                  min(s.week_no))
  INTO v_week
  FROM public.team_onboarding_steps s
  WHERE s.plan_id = p_plan_id AND s.title = 'Watch' AND s.week_no IS NOT NULL;

  WITH cur AS MATERIALIZED (
    SELECT x.e, x.ord
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v_plan.orientation_videos) = 'array'
                                   THEN v_plan.orientation_videos ELSE '[]'::jsonb END) WITH ORDINALITY AS x(e, ord)
  ), kept AS MATERIALIZED (
    SELECT c.e, c.ord
    FROM cur c
    WHERE c.e ->> 'label' = ANY (COALESCE(p_videos, '{}'::text[]))
       OR EXISTS (
         SELECT 1 FROM public.team_onboarding_steps s
         WHERE s.plan_id = p_plan_id AND s.title = 'Watch'
           AND s.week_no::text = c.e ->> 'week'
           AND jsonb_typeof(s.substeps_done) = 'array'
           AND s.substeps_done ? (c.e ->> 'label'))
  ), added AS MATERIALIZED (
    SELECT jsonb_build_object('label', u.v, 'week', v_week) AS e, 100000 + min(u.o) AS ord
    FROM unnest(COALESCE(p_videos, '{}'::text[])) WITH ORDINALITY AS u(v, o)
    WHERE v_week IS NOT NULL
      AND COALESCE(u.v, '') <> ''
      AND NOT EXISTS (SELECT 1 FROM cur c WHERE c.e ->> 'label' = u.v)
    GROUP BY u.v
  )
  SELECT COALESCE(jsonb_agg(z.e ORDER BY z.ord), '[]'::jsonb) INTO v_next
  FROM (SELECT e, ord FROM kept UNION ALL SELECT e, ord FROM added) z;

  IF v_next IS DISTINCT FROM v_plan.orientation_videos THEN
    UPDATE public.team_onboarding_plans SET orientation_videos = v_next WHERE id = p_plan_id;
    v_sync := public.onboarding_sync_plan(p_plan_id);
    -- A Watch card that was already finished opens again when videos land on it.
    UPDATE public.team_onboarding_steps s
    SET completed_at = NULL, completed_by = NULL
    WHERE s.plan_id = p_plan_id AND s.title = 'Watch' AND s.completed_at IS NOT NULL
      AND public.onboarding_substeps_missing(s.substeps, s.substeps_done) > 0;
  END IF;

  RETURN jsonb_build_object('plan_id', p_plan_id, 'week', v_week, 'videos', v_next, 'sync', v_sync);
END;
$function$;

REVOKE ALL ON FUNCTION public.onboarding_orientation_videos(uuid, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.onboarding_orientation_videos(uuid, text[]) TO authenticated, service_role;
