-- =========================================================================
-- Onboarding steps get a date, not just an order
-- =========================================================================
-- The notice I sent Alvi listed four things. Only one of them was actually
-- due. The other three — door and alarm codes, the spare door key, business
-- cards — sit in phases "Weeks 3-4" and "Weeks 5-8" and are not needed for a
-- fortnight or more. My open-step test only asked whether a step was blocked
-- by an unfinished step, and none of those three are blocked by anything, so
-- they read as ready on day one.
--
-- Same root cause put every one of Bryson's seven onboarding tasks on a due
-- date of today, including the week-14 ones: the task writer collapsed every
-- ramp phase to the start date.
--
-- The fix is to give the phase table the one thing it was missing — how many
-- days after the start date the phase begins — and have both the notice and
-- the task due date read it. One place to edit, and the prose in the step
-- descriptions stops being the only record of when something is due.
-- =========================================================================

ALTER TABLE public.onboarding_phases
  ADD COLUMN IF NOT EXISTS days_from_start integer;

COMMENT ON COLUMN public.onboarding_phases.days_from_start IS
  'Days after the start date that this phase opens. Negative means before the start date, which in practice means "as soon as the plan exists". Drives both the task due date and whether a step is announced yet.';

UPDATE public.onboarding_phases SET days_from_start = v.d
FROM (VALUES (10,-21),(15,-21),(20,-14),(25,-14),(30,-10),(35,-7),(40,-3),
             (50,0),(55,0),(60,14),(65,28),(70,56),(75,91)) AS v(p,d)
WHERE onboarding_phases.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND onboarding_phases.phase = v.p;

-- One place for the address of the app, so an email can link back to it.
INSERT INTO public.settings (agency_id, setting_key, setting_value)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'app_base_url', 'https://newtworks.vercel.app'
WHERE NOT EXISTS (
  SELECT 1 FROM public.settings
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND setting_key='app_base_url');


-- -------------------------------------------------------------------------
-- The notice: only announce a step whose phase has actually opened, and put
-- a link in it.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.onboarding_open_step_notices(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  p_recipe_id uuid DEFAULT NULL::uuid)
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
  v_base   text;
  v_link   text;
  v_people int := 0;
  v_steps  int := 0;
  v_emails int := 0;
BEGIN
  PERFORM public.onboarding_sync_reference_steps(p_agency_id);

  v_base := COALESCE(public.get_setting(p_agency_id, 'app_base_url'), 'https://newtworks.vercel.app');

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
      LEFT JOIN public.onboarding_phases ph
        ON ph.agency_id = p.agency_id AND ph.phase = s.phase
      WHERE p.agency_id = p_agency_id
        AND p.status = 'active'
        AND s.assigned_to IS NOT NULL
        AND s.completed_at IS NULL
        AND s.opened_notified_at IS NULL
        -- the phase has to have started. A negative offset is pre-start work,
        -- which is open the moment the plan exists.
        AND CURRENT_DATE >= p.start_date + COALESCE(ph.days_from_start, 0)
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
    v_link   := v_base || '/onboarding?plan=' || g.plan_id::text;

    v_line := CASE WHEN array_length(v_titles, 1) = 1
                   THEN '1 onboarding step is ready for you'
                   ELSE array_length(v_titles, 1)::text || ' onboarding steps are ready for you' END;

    v_tg := '<b>' || g.first_name || ' — ' || v_line || '</b>' || E'\n' ||
            'Onboarding for ' || g.subject_name ||
            CASE WHEN g.start_date IS NULL THEN ''
                 ELSE ', starting ' || to_char(g.start_date, 'Dy Mon FMDD') END || E'\n\n' ||
            (SELECT string_agg('• ' || t, E'\n') FROM unnest(v_titles) t) || E'\n\n' ||
            'They are on your task list in Newtworks: ' || v_link;

    PERFORM public.telegram_send('admin', v_tg, p_agency_id, 'HTML');

    IF g.email IS NOT NULL THEN
      v_html := '<p>Hi ' || g.first_name || ',</p>' ||
                '<p>' || v_line || ' on the onboarding schedule for <b>' || g.subject_name || '</b>' ||
                CASE WHEN g.start_date IS NULL THEN ''
                     ELSE ', who starts ' || to_char(g.start_date, 'Dy Mon FMDD') END || '.</p><ul>' ||
                (SELECT string_agg('<li>' || t || '</li>', '') FROM unnest(v_titles) t) ||
                '</ul>' ||
                '<p>They are on your task list, and the whole checklist is here: ' ||
                '<a href="' || v_link || '">Open ' || g.subject_name || '''s onboarding in Newtworks</a></p>' ||
                '<p>Nothing else on that checklist needs you yet. Anything dated later will turn up in another note when it does.</p>';

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
