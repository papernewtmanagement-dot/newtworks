-- =========================================================================
-- Onboarding part 2: tell the assignee when a step opens
-- =========================================================================
-- A step opens when it is not done, it is assigned to someone, and every
-- step it was waiting on is finished. The assignee gets a Telegram message
-- in the Paper Newt Management group and an email. Each step once.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.onboarding_open_step_notices(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  p_recipe_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'net'
AS $function$
DECLARE
  g        record;
  v_titles text[];
  v_ids    uuid[];
  v_tg     text;
  v_html   text;
  v_line   text;
  v_people int := 0;
  v_steps  int := 0;
  v_emails int := 0;
BEGIN
  PERFORM public.onboarding_sync_reference_steps(p_agency_id);

  FOR g IN
    WITH open_steps AS (
      SELECT s.id, s.title, s.assigned_to, s.plan_id, p.start_date,
             COALESCE(
               NULLIF(TRIM(COALESCE(t.nickname, t.first_name) || ' ' || COALESCE(t.last_name, '')), ''),
               NULLIF(TRIM(COALESCE(c.first_name, '') || ' ' || COALESCE(c.last_name, '')), ''),
               c.candidate_name, 'the new hire') AS subject_name
      FROM public.team_onboarding_steps s
      JOIN public.team_onboarding_plans p ON p.id = s.plan_id
      LEFT JOIN public.team t ON t.id = p.team_member_id
      LEFT JOIN public.hiring_candidates c ON c.id = p.candidate_id
      WHERE p.agency_id = p_agency_id
        AND p.status = 'active'
        AND s.assigned_to IS NOT NULL
        AND s.completed_at IS NULL
        AND s.opened_notified_at IS NULL
        AND NOT EXISTS (
          SELECT 1
          FROM unnest(COALESCE(s.blocked_by, ARRAY[]::text[])) b
          JOIN public.team_onboarding_steps bs
            ON bs.plan_id = s.plan_id AND bs.template_key = b
          WHERE bs.completed_at IS NULL
        )
    )
    SELECT o.assigned_to, o.plan_id, o.subject_name, o.start_date,
           COALESCE(NULLIF(TRIM(COALESCE(tm.nickname, tm.first_name)), ''), 'there') AS first_name,
           COALESCE(NULLIF(tm.email_personal, ''), NULLIF(tm.email_sf, '')) AS email,
           array_agg(o.title ORDER BY o.title) AS titles,
           array_agg(o.id) AS step_ids
    FROM open_steps o
    JOIN public.team tm ON tm.id = o.assigned_to
    GROUP BY o.assigned_to, o.plan_id, o.subject_name, o.start_date,
             tm.nickname, tm.first_name, tm.email_personal, tm.email_sf
  LOOP
    v_titles := g.titles;
    v_ids    := g.step_ids;

    v_line := CASE WHEN array_length(v_titles, 1) = 1
                   THEN '1 onboarding step is ready for you'
                   ELSE array_length(v_titles, 1)::text || ' onboarding steps are ready for you' END;

    v_tg := '<b>' || g.first_name || ' — ' || v_line || '</b>' || E'\n' ||
            'Onboarding for ' || g.subject_name ||
            CASE WHEN g.start_date IS NULL THEN ''
                 ELSE ', starting ' || to_char(g.start_date, 'Dy Mon FMDD') END || E'\n\n' ||
            (SELECT string_agg('• ' || t, E'\n') FROM unnest(v_titles) t) || E'\n\n' ||
            'They are on your task list in Newtworks.';

    PERFORM public.telegram_send('admin', v_tg, p_agency_id, 'HTML');

    IF g.email IS NOT NULL THEN
      v_html := '<p>Hi ' || g.first_name || ',</p>' ||
                '<p>' || v_line || ' on the onboarding schedule for <b>' || g.subject_name || '</b>' ||
                CASE WHEN g.start_date IS NULL THEN ''
                     ELSE ', who starts ' || to_char(g.start_date, 'Dy Mon FMDD') END || '.</p><ul>' ||
                (SELECT string_agg('<li>' || t || '</li>', '') FROM unnest(v_titles) t) ||
                '</ul><p>They are on your task list in Newtworks.</p>';

      PERFORM public.composio_send_email(
        p_agency_id, g.email,
        g.subject_name || ' onboarding — ' || v_line, v_html);
      v_emails := v_emails + 1;
    END IF;

    UPDATE public.team_onboarding_steps
    SET opened_notified_at = now()
    WHERE id = ANY (v_ids);

    v_people := v_people + 1;
    v_steps  := v_steps + array_length(v_titles, 1);
  END LOOP;

  RETURN jsonb_build_object('people', v_people, 'steps', v_steps, 'emails', v_emails);
END;
$function$;

COMMENT ON FUNCTION public.onboarding_open_step_notices(uuid, uuid) IS
  'Tells whoever a step is assigned to that it just opened — Telegram to the Paper Newt Management group plus an email. A step is announced once. Runs on the hourly automation tick.';

GRANT EXECUTE ON FUNCTION public.onboarding_open_step_notices(uuid, uuid) TO authenticated, service_role;

INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
  internal_handler, is_active, timezone
)
SELECT '126794dd-25ff-47d2-a436-724499733365',
       'Onboarding — open step notices',
       'Tells whoever a step is assigned to that it just opened. Telegram to the Paper Newt Management group plus an email. Also refreshes the self-ticking reference steps.',
       'cron', '59 7-19 * * *', 'onboarding_open_step_notices', true, 'America/Chicago'
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND internal_handler = 'onboarding_open_step_notices'
);
