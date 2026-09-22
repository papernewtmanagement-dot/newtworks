-- Onboarding 2026-09-22, third pass (Peter).
-- 1) Card and step titles are title case. title_case() is the one place the
--    rule lives; triggers apply it on every write to step titles and phase
--    names, so a new card cannot come in lower case.
-- 2) Tech setup -> Setup.
-- 3) A step can belong to the whole team (owner_kind = 'team'). Every
--    teammate but the new hire can see and tick it. When it opens, each
--    teammate gets an email and a task; ticking your own name closes your
--    task, and closing your task ticks your name.
-- 4) New card: Team Adds the New Hire, opened by Get System Access. The two
--    "add new TM to ... of all other team members" lines move onto it.
-- 5) Outlook card: the out of office steps move to the out-of-office
--    checklist item; the sections they were mixed into get their own
--    headings back, as on the Confluence page.
-- 6) onboarding_step_is_open() is the one test for "this step has opened",
--    used by both notice functions. task_tick_syncs_onboarding_step now
--    counts open sub-items with onboarding_substeps_missing() instead of its
--    own copy, which ignored archived alternatives.

CREATE OR REPLACE FUNCTION public.title_case(p_text text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
-- Title case for card and step titles (AP style: short articles,
-- conjunctions and prepositions stay lower case unless first, last, or right
-- after a colon or dash). Only ever raises a first letter; never lowers a
-- word written in capitals (ECRM, SCF, FIT, IT stay as typed).
DECLARE
  v_small text[] := ARRAY['a','an','the','and','but','or','nor','for','so','yet',
                          'as','at','by','in','of','on','per','to','via','vs'];
  v_words text[];
  v_out   text[] := '{}';
  v_n     int;
  v_i     int;
  v_word  text;
  v_prev  text := NULL;
  v_seg   text;
  v_segs  text[];
  v_lead  text;
  v_rest  text;
  v_built text;
  v_seps  text[];
  v_j     int;
BEGIN
  IF p_text IS NULL THEN RETURN NULL; END IF;
  v_words := regexp_split_to_array(p_text, ' ');
  v_n := array_length(v_words, 1);
  FOR v_i IN 1 .. v_n LOOP
    v_word := v_words[v_i];
    IF v_word = '' THEN
      v_out := v_out || v_word;
      CONTINUE;
    END IF;
    IF v_i > 1 AND v_i < v_n
       AND lower(v_word) = ANY (v_small)
       AND v_word ~ '^[A-Z]?[a-z]+$'
       AND NOT (v_prev ~ '[:—–-]$') THEN
      v_out := v_out || lower(v_word);
    ELSE
      -- raise the first letter of each part split on - or /
      v_segs := regexp_split_to_array(v_word, '[-/]');
      v_seps := ARRAY(SELECT (regexp_matches(v_word, '[-/]', 'g'))[1]);
      v_built := '';
      FOR v_j IN 1 .. array_length(v_segs, 1) LOOP
        v_seg  := v_segs[v_j];
        v_lead := COALESCE(substring(v_seg from '^[^A-Za-z0-9]*'), '');
        v_rest := substr(v_seg, length(v_lead) + 1);
        IF v_rest ~ '^[a-z]' THEN
          v_rest := upper(left(v_rest, 1)) || substr(v_rest, 2);
        END IF;
        v_built := v_built || v_lead || v_rest
                   || CASE WHEN v_j <= COALESCE(array_length(v_seps, 1), 0) THEN v_seps[v_j] ELSE '' END;
      END LOOP;
      v_out := v_out || v_built;
    END IF;
    v_prev := v_word;
  END LOOP;
  RETURN array_to_string(v_out, ' ');
END;
$$;

CREATE OR REPLACE FUNCTION public.onboarding_title_case_trg()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_TABLE_NAME = 'onboarding_phases' THEN
    NEW.name := public.title_case(NEW.name);
  ELSE
    NEW.title := public.title_case(NEW.title);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_onboarding_template_title_case ON public.onboarding_step_templates;
CREATE TRIGGER trg_onboarding_template_title_case
  BEFORE INSERT OR UPDATE OF title ON public.onboarding_step_templates
  FOR EACH ROW EXECUTE FUNCTION public.onboarding_title_case_trg();

DROP TRIGGER IF EXISTS trg_onboarding_phase_title_case ON public.onboarding_phases;
CREATE TRIGGER trg_onboarding_phase_title_case
  BEFORE INSERT OR UPDATE OF name ON public.onboarding_phases
  FOR EACH ROW EXECUTE FUNCTION public.onboarding_title_case_trg();

-- ─── owner_kind 'team' ─────────────────────────────────────────────────
DO $mig$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT conrelid::regclass AS tbl, conname
    FROM pg_constraint
    WHERE conrelid IN ('public.onboarding_step_templates'::regclass, 'public.team_onboarding_steps'::regclass)
      AND contype = 'c' AND pg_get_constraintdef(oid) ILIKE '%owner_kind%'
  LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.tbl, r.conname);
  END LOOP;
END
$mig$;
ALTER TABLE public.onboarding_step_templates ADD CONSTRAINT onboarding_step_templates_owner_kind_check
  CHECK (owner_kind = ANY (ARRAY['new_hire','agent','admin','team']));
ALTER TABLE public.team_onboarding_steps ADD CONSTRAINT team_onboarding_steps_owner_kind_check
  CHECK (owner_kind = ANY (ARRAY['new_hire','agent','admin','team']));

-- How a teammate is named on a checklist. Used by the team list fill and by
-- the team-card task link, so the two always agree.
CREATE OR REPLACE FUNCTION public.onboarding_team_label(p_team public.team)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(TRIM(COALESCE(NULLIF(TRIM(p_team.nickname), ''), p_team.first_name)
                     || ' ' || COALESCE(p_team.last_name, '')), '');
$$;

CREATE OR REPLACE FUNCTION public.onboarding_fill_substeps(p_substeps jsonb, p_plan_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT CASE
    WHEN jsonb_typeof(p_substeps) <> 'array' OR p_substeps IS NULL THEN p_substeps
    WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_substeps) e
                     WHERE jsonb_typeof(e) = 'object' AND e ->> 'fill' = 'team_list') THEN p_substeps
    ELSE (
      SELECT jsonb_agg(
               CASE WHEN jsonb_typeof(e) = 'object' AND e ->> 'fill' = 'team_list'
                    THEN jsonb_set(e, '{items}', COALESCE((
                           SELECT jsonb_agg(n ORDER BY n)
                           FROM (
                             SELECT DISTINCT public.onboarding_team_label(tm) AS n
                             FROM public.team tm
                             JOIN public.team_onboarding_plans p ON p.id = p_plan_id
                             WHERE tm.agency_id = p.agency_id
                               AND tm.is_active IS TRUE
                               AND tm.archived_at IS NULL
                               AND COALESCE(tm.is_test_user, false) = false
                               AND tm.id IS DISTINCT FROM p.team_member_id
                           ) names
                           WHERE n IS NOT NULL), '[]'::jsonb))
                    ELSE e END
               ORDER BY ord)
      FROM jsonb_array_elements(p_substeps) WITH ORDINALITY AS x(e, ord)
    )
  END;
$$;

-- Visibility: team cards are open to every teammate except the new hire.
CREATE OR REPLACE FUNCTION public.onboarding_can_see_step(p_plan_id uuid, p_phase integer, p_assigned_to uuid, p_auto_source text, p_owner_kind text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_me uuid; v_agency uuid;
  pl record;
BEGIN
  IF auth.uid() IS NULL THEN RETURN false; END IF;
  SELECT u.team_member_id, u.agency_id INTO v_me, v_agency
  FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1;

  SELECT p.agency_id, p.team_member_id, p.candidate_id INTO pl
  FROM public.team_onboarding_plans p WHERE p.id = p_plan_id;
  IF NOT FOUND OR pl.agency_id IS DISTINCT FROM v_agency THEN RETURN false; END IF;

  IF public.is_agency_admin() THEN RETURN true; END IF;
  IF v_me IS NULL THEN RETURN false; END IF;

  IF p_assigned_to = v_me THEN RETURN true; END IF;

  IF p_owner_kind = 'team' AND pl.team_member_id IS DISTINCT FROM v_me THEN
    RETURN true;
  END IF;

  IF p_auto_source = 'references' AND pl.candidate_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.hiring_reference_callers(pl.candidate_id) k
                 WHERE k.team_member_id = v_me) THEN
    RETURN true;
  END IF;

  IF pl.team_member_id = v_me AND EXISTS (
       SELECT 1 FROM public.onboarding_phases ph
       WHERE ph.agency_id = pl.agency_id AND ph.phase = p_phase AND ph.stage = 'ramp') THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

DROP POLICY IF EXISTS tos_select ON public.team_onboarding_steps;
CREATE POLICY tos_select ON public.team_onboarding_steps FOR SELECT
  USING (public.onboarding_can_see_step(plan_id, phase, assigned_to, auto_source, owner_kind));
DROP POLICY IF EXISTS tos_update ON public.team_onboarding_steps;
CREATE POLICY tos_update ON public.team_onboarding_steps FOR UPDATE
  USING (public.onboarding_can_see_step(plan_id, phase, assigned_to, auto_source, owner_kind))
  WITH CHECK (public.onboarding_can_see_step(plan_id, phase, assigned_to, auto_source, owner_kind));

CREATE OR REPLACE FUNCTION public.onboarding_can_see_plan(p_plan_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_me uuid; v_agency uuid; pl record;
BEGIN
  IF auth.uid() IS NULL THEN RETURN false; END IF;
  SELECT u.team_member_id, u.agency_id INTO v_me, v_agency
  FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1;
  SELECT p.agency_id, p.team_member_id INTO pl
  FROM public.team_onboarding_plans p WHERE p.id = p_plan_id;
  IF NOT FOUND OR pl.agency_id IS DISTINCT FROM v_agency THEN RETURN false; END IF;
  IF public.is_agency_admin() THEN RETURN true; END IF;
  IF v_me IS NOT NULL AND pl.team_member_id = v_me THEN RETURN true; END IF;
  RETURN EXISTS (
    SELECT 1 FROM public.team_onboarding_steps s
    WHERE s.plan_id = p_plan_id
      AND public.onboarding_can_see_step(s.plan_id, s.phase, s.assigned_to, s.auto_source, s.owner_kind));
END;
$function$;

DROP FUNCTION IF EXISTS public.onboarding_can_see_step(uuid, integer, uuid, text);

-- ─── one test for "this step has opened" ──────────────────────────────
CREATE OR REPLACE FUNCTION public.onboarding_step_is_open(p_step_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT COALESCE((
    SELECT s.completed_at IS NULL
       AND p.status = 'active'
       -- the phase has to have started. A negative offset is pre-start work,
       -- which is open the moment the plan exists.
       AND CURRENT_DATE >= public.onboarding_phase_opens_on(p.agency_id, s.phase, p.start_date)
       AND (s.unlocks_on IS NULL
            OR s.unlocks_on <= (now() AT TIME ZONE 'America/Chicago')::date)
       AND NOT EXISTS (
         SELECT 1
         FROM unnest(COALESCE(s.blocked_by, ARRAY[]::text[])) b
         JOIN public.team_onboarding_steps bs
           ON bs.plan_id = s.plan_id AND bs.template_key = b
         WHERE bs.completed_at IS NULL)
    FROM public.team_onboarding_steps s
    JOIN public.team_onboarding_plans p ON p.id = s.plan_id
    WHERE s.id = p_step_id), false);
$$;

-- ─── team cards: email + a task for each teammate when the card opens ──
CREATE OR REPLACE FUNCTION public.onboarding_team_card_notices(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  s        record;
  tm       record;
  v_base   text;
  v_link   text;
  v_labels text[];
  v_user   uuid;
  v_first  text;
  v_email  text;
  v_html   text;
  v_cards  int := 0;
  v_mails  int := 0;
  v_tasks  int := 0;
BEGIN
  v_base := COALESCE(public.get_setting(p_agency_id, 'app_base_url'), 'https://newtworks.vercel.app');

  FOR s IN
    SELECT st.id, st.title, st.description, st.plan_id, st.substeps, p.start_date, p.team_member_id,
           COALESCE(
             NULLIF(TRIM(COALESCE(t.nickname, t.first_name) || ' ' || COALESCE(t.last_name, '')), ''),
             NULLIF(TRIM(COALESCE(c.first_name, '') || ' ' || COALESCE(c.last_name, '')), ''),
             c.candidate_name, 'the new hire') AS subject_name
    FROM public.team_onboarding_steps st
    JOIN public.team_onboarding_plans p ON p.id = st.plan_id
    LEFT JOIN public.team t ON t.id = p.team_member_id
    LEFT JOIN public.hiring_candidates c ON c.id = p.candidate_id
    WHERE p.agency_id = p_agency_id
      AND st.owner_kind = 'team'
      AND st.opened_notified_at IS NULL
      AND public.onboarding_step_is_open(st.id)
  LOOP
    v_link   := v_base || '/onboarding?plan=' || s.plan_id::text;
    v_labels := public.onboarding_substep_labels(s.substeps);

    FOR tm IN
      SELECT x.*
      FROM public.team x
      WHERE x.agency_id = p_agency_id
        AND x.is_active IS TRUE
        AND x.archived_at IS NULL
        AND COALESCE(x.is_test_user, false) = false
        AND x.id IS DISTINCT FROM s.team_member_id
        AND public.onboarding_team_label(x) = ANY (v_labels)
    LOOP
      v_first := COALESCE(NULLIF(TRIM(COALESCE(tm.nickname, tm.first_name)), ''), 'there');
      v_email := COALESCE(NULLIF(tm.email_personal, ''), NULLIF(tm.email_sf, ''));

      SELECT u.id INTO v_user FROM public.users u WHERE u.team_member_id = tm.id LIMIT 1;
      IF v_user IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM public.tasks k
           WHERE k.related_id = s.id AND k.created_by = 'onboarding_team_card' AND k.assigned_to = v_user) THEN
        INSERT INTO public.tasks (agency_id, title, description, assigned_to, task_category, task_type,
                                  status, due_date, related_id, created_by)
        VALUES (p_agency_id, 'Onboarding — ' || s.subject_name || ': ' || s.title,
                COALESCE(s.description, '') || E'\n\nTick your name on the card when it is done: ' || v_link,
                v_user, 'admin', 'task', 'open', CURRENT_DATE, s.id, 'onboarding_team_card');
        v_tasks := v_tasks + 1;
      END IF;
      v_user := NULL;

      IF v_email IS NOT NULL THEN
        v_html := '<p>Hi ' || v_first || ',</p>' ||
                  '<p><b>' || s.subject_name || '</b> has State Farm system access now' ||
                  CASE WHEN s.start_date IS NULL THEN '' ELSE ' and starts ' || to_char(s.start_date, 'Dy Mon FMDD') END ||
                  '. Please add them to your Outlook and your Jabber.</p>' ||
                  '<p>Then tick your name on the <b>' || s.title || '</b> card so we know it is done: ' ||
                  '<a href="' || v_link || '">Open ' || s.subject_name || '''s onboarding in Newtworks</a></p>' ||
                  '<p>It is on your task list too. Ticking your name closes it.</p>';
        PERFORM public.composio_send_email(p_agency_id, v_email,
          s.subject_name || ' onboarding — add them to your Outlook and Jabber', v_html);
        v_mails := v_mails + 1;
      END IF;
    END LOOP;

    UPDATE public.team_onboarding_steps SET opened_notified_at = now() WHERE id = s.id;
    v_cards := v_cards + 1;
  END LOOP;

  RETURN jsonb_build_object('cards', v_cards, 'emails', v_mails, 'tasks', v_tasks);
END;
$function$;

DO $mig$
DECLARE
  v_def text;
  v_new text;
BEGIN
  v_def := pg_get_functiondef('public.onboarding_open_step_notices(uuid,uuid)'::regprocedure);
  v_new := replace(v_def,
$a$        AND s.assigned_to IS NOT NULL
        AND s.completed_at IS NULL
        AND s.opened_notified_at IS NULL
        -- the phase has to have started. A negative offset is pre-start work,
        -- which is open the moment the plan exists.
        AND CURRENT_DATE >= public.onboarding_phase_opens_on(p.agency_id, s.phase, p.start_date)
        AND (s.unlocks_on IS NULL
             OR s.unlocks_on <= (now() AT TIME ZONE 'America/Chicago')::date)
        AND NOT EXISTS (
          SELECT 1
          FROM unnest(COALESCE(s.blocked_by, ARRAY[]::text[])) b
          JOIN public.team_onboarding_steps bs
            ON bs.plan_id = s.plan_id AND bs.template_key = b
          WHERE bs.completed_at IS NULL
        )$a$,
$b$        AND s.assigned_to IS NOT NULL
        AND s.opened_notified_at IS NULL
        AND public.onboarding_step_is_open(s.id)$b$);
  v_new := replace(v_new,
$a$  PERFORM public.onboarding_sync_reference_steps(p_agency_id);$a$,
$b$  PERFORM public.onboarding_sync_reference_steps(p_agency_id);
  PERFORM public.onboarding_team_card_notices(p_agency_id);$b$);
  IF v_new = v_def
     OR position('public.onboarding_step_is_open(s.id)' IN v_new) = 0
     OR position('onboarding_team_card_notices' IN v_new) = 0 THEN
    RAISE EXCEPTION 'onboarding_open_step_notices patch did not apply cleanly';
  END IF;
  EXECUTE v_new;
END
$mig$;

-- A teammate's task on a team card is their own name on it. Either side
-- moves the other.
CREATE OR REPLACE FUNCTION public.onboarding_team_card_tasks_sync()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM public.tasks WHERE related_id = OLD.id AND created_by = 'onboarding_team_card';
    RETURN OLD;
  END IF;
  IF NEW.owner_kind IS DISTINCT FROM 'team' THEN RETURN NEW; END IF;

  UPDATE public.tasks t
  SET status       = CASE WHEN x.done THEN 'completed' ELSE 'open' END,
      completed_at = CASE WHEN x.done THEN now() ELSE NULL END,
      updated_at   = now()
  FROM (
    SELECT k.id,
           (NEW.completed_at IS NOT NULL
            OR public.onboarding_team_label(tm) = ANY (public.onboarding_substep_labels(
                 CASE WHEN jsonb_typeof(NEW.substeps_done) = 'array' THEN NEW.substeps_done ELSE '[]'::jsonb END))) AS done
    FROM public.tasks k
    JOIN public.users u ON u.id = k.assigned_to
    JOIN public.team tm ON tm.id = u.team_member_id
    WHERE k.related_id = NEW.id AND k.created_by = 'onboarding_team_card'
  ) x
  WHERE t.id = x.id
    AND (t.status = 'completed') IS DISTINCT FROM x.done;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_onboarding_team_card_tasks ON public.team_onboarding_steps;
CREATE TRIGGER trg_onboarding_team_card_tasks
  AFTER UPDATE OF substeps_done, completed_at OR DELETE ON public.team_onboarding_steps
  FOR EACH ROW EXECUTE FUNCTION public.onboarding_team_card_tasks_sync();

CREATE OR REPLACE FUNCTION public.task_tick_syncs_onboarding_step()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  s       record;
  v_label text;
BEGIN
  IF NEW.related_id IS NULL OR NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  SELECT id, completed_at, auto_source, substeps, substeps_done, owner_kind
  INTO s
  FROM public.team_onboarding_steps
  WHERE id = NEW.related_id;

  IF NOT FOUND OR s.auto_source IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- Team card: this task is one teammate's own line on it.
  IF s.owner_kind = 'team' THEN
    SELECT public.onboarding_team_label(tm) INTO v_label
    FROM public.users u JOIN public.team tm ON tm.id = u.team_member_id
    WHERE u.id = NEW.assigned_to;
    IF v_label IS NULL OR NOT (v_label = ANY (public.onboarding_substep_labels(s.substeps))) THEN
      RETURN NEW;
    END IF;
    IF NEW.status = 'completed' THEN
      UPDATE public.team_onboarding_steps
      SET substeps_done = COALESCE(CASE WHEN jsonb_typeof(substeps_done) = 'array' THEN substeps_done END, '[]'::jsonb)
                          || jsonb_build_array(v_label),
          updated_at = now()
      WHERE id = s.id
        AND NOT (COALESCE(CASE WHEN jsonb_typeof(substeps_done) = 'array' THEN substeps_done END, '[]'::jsonb) ? v_label);
      UPDATE public.team_onboarding_steps
      SET completed_at = now(), completed_by = COALESCE(completed_by, NEW.assigned_to), updated_at = now()
      WHERE id = s.id AND completed_at IS NULL
        AND public.onboarding_substeps_missing(substeps, substeps_done) = 0;
    ELSE
      UPDATE public.team_onboarding_steps
      SET substeps_done = substeps_done - v_label,
          completed_at  = NULL,
          completed_by  = NULL,
          updated_at    = now()
      WHERE id = s.id AND jsonb_typeof(substeps_done) = 'array' AND substeps_done ? v_label;
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.status = 'completed' AND s.completed_at IS NULL THEN
    IF public.onboarding_substeps_missing(s.substeps, s.substeps_done) > 0 THEN
      RETURN NEW;   -- sub-items still open; the checklist stays the record
    END IF;

    UPDATE public.team_onboarding_steps
    SET completed_at = now(),
        completed_by = COALESCE(completed_by, NEW.assigned_to),
        updated_at   = now()
    WHERE id = s.id;

  ELSIF NEW.status <> 'completed' AND s.completed_at IS NOT NULL THEN
    UPDATE public.team_onboarding_steps
    SET completed_at = NULL,
        completed_by = NULL,
        updated_at   = now()
    WHERE id = s.id;
  END IF;

  RETURN NEW;
END;
$function$;

-- ─── template data ─────────────────────────────────────────────────────
SELECT set_config('app.onboarding_template_sync', 'off', true);

UPDATE public.onboarding_phases SET name = public.title_case(name), updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';
UPDATE public.onboarding_phases
   SET name = 'Setup',
       blurb = 'Log in first. The other Setup cards and Weeks 1-2 open once Login is done.',
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND phase = 50;
UPDATE public.onboarding_step_templates
   SET description = 'Do this first. The other Setup cards and Weeks 1-2 open once it is done.'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_login'
   AND description = 'Do this first. The other tech cards and Weeks 1-2 open once it is done.';

UPDATE public.onboarding_step_templates SET title = public.title_case(title)
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- The team card. It opens when system access is in.
INSERT INTO public.onboarding_step_templates
  (agency_id, template_key, title, description, phase, category, owner_kind, assigned_to,
   is_required, sort_order, is_active, substeps, blocked_by, track, track_order)
SELECT '126794dd-25ff-47d2-a436-724499733365', 't_team_adds_new_hire', 'Team Adds the New Hire',
       'Every team member adds the new TM to their own Outlook and their own Jabber, then ticks their name.',
       10, 'systems', 'team', NULL, true, 40, true,
       '[{"group": "Add new TM to Outlook and Jabber, then tick your name", "fill": "team_list", "items": []}]'::jsonb,
       ARRAY['p0_ecrm_account'], t.track, t.track_order
FROM public.onboarding_step_templates t
WHERE t.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND t.template_key = 'agent_tech_setup'
ON CONFLICT DO NOTHING;

-- Those two lines leave the Outlook and Jabber cards. A group left empty goes.
UPDATE public.onboarding_step_templates t
   SET substeps = (
     SELECT jsonb_agg(g ORDER BY ord)
     FROM (
       SELECT ord,
              CASE WHEN jsonb_typeof(e) = 'object' THEN
                     jsonb_set(e, '{items}', COALESCE((
                       SELECT jsonb_agg(i ORDER BY io)
                       FROM jsonb_array_elements(e -> 'items') WITH ORDINALITY AS y(i, io)
                       WHERE i #>> '{}' NOT IN ('Add new TM to Outlook of all other team members',
                                                'Add new TM to Jabber of all other team members')), '[]'::jsonb))
                   ELSE e END AS g
       FROM jsonb_array_elements(t.substeps) WITH ORDINALITY AS x(e, ord)
       WHERE NOT (jsonb_typeof(e) = 'string'
                  AND e #>> '{}' IN ('Add new TM to Outlook of all other team members',
                                     'Add new TM to Jabber of all other team members'))
     ) z
     WHERE jsonb_typeof(g) <> 'object'
        OR jsonb_array_length(g -> 'items') > 0
        OR g ->> 'fill' IS NOT NULL)
 WHERE t.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND t.template_key IN ('outlook', 't_jabber');

-- Outlook: the out of office steps go to the checklist. The lines that were
-- sitting under that heading get their Confluence headings back.
UPDATE public.onboarding_step_templates t
   SET substeps = (
     SELECT jsonb_agg(g ORDER BY ord, sub)
     FROM (
       SELECT ord, 1 AS sub,
              CASE WHEN e ->> 'group' = 'Create an out of office reply'
                     THEN jsonb_build_object('group', 'Setup Contact Groups',
                                             'items', jsonb_path_query_array(e -> 'items', '$[5 to 8]'))
                   WHEN e ->> 'group' = 'Instructions'
                     THEN jsonb_set(e, '{group}', '"Give agent access"')
                   ELSE e END AS g
       FROM jsonb_array_elements(t.substeps) WITH ORDINALITY AS x(e, ord)
       UNION ALL
       SELECT ord, 2, jsonb_build_object('group', 'Add the shared directory',
                                         'items', jsonb_path_query_array(e -> 'items', '$[10 to 12]'))
       FROM jsonb_array_elements(t.substeps) WITH ORDINALITY AS x(e, ord)
       WHERE e ->> 'group' = 'Create an out of office reply'
     ) z)
 WHERE t.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND t.template_key = 'outlook'
   AND EXISTS (
     SELECT 1 FROM jsonb_array_elements(t.substeps) e
     WHERE e ->> 'group' = 'Create an out of office reply'
       AND e -> 'items' ->> 0  = 'File > Automatic Replies (Out of Office)'
       AND e -> 'items' ->> 4  = 'Setup Contact Groups'
       AND e -> 'items' ->> 9  = 'Add the shared directory'
       AND e -> 'items' ->> 13 = 'Give agent access'
       AND jsonb_array_length(e -> 'items') = 14);

-- The out of office steps, now on the out-of-office checklist item.
UPDATE public.checklist_items
   SET help_text = help_text || E'\n\nTo set it up in Outlook:\n\n' ||
       E'1. File > Automatic Replies (Out of Office)\n' ||
       E'2. Click the radio button: “Send automatic replies”\n' ||
       E'3. Select “Outside My Organization” and paste:\n\n' ||
       E'“Thanks for reaching out. Our office is open Monday-Thursday from 10-5. We''ll get back to you once we''re back in office. Thanks for trusting Peter Story State Farm to look after you. Have a great day!”',
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND item_key = 'ooo'
   AND help_text NOT LIKE '%Automatic Replies%';

SELECT set_config('app.onboarding_template_sync', 'on', true);
SELECT public.onboarding_sync_open_plans();
