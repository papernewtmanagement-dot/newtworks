-- ── 1. A line under two headings is ticked under each ──────────────────────
-- Every sub-item line on a card, with the heading it sits under and the text
-- it is ticked under in substeps_done. Usually that is the line itself. A line
-- that appears under more than one heading on the same card (a team list
-- repeated per heading) is ticked separately under each, as
-- "<heading> › <line>". subGroups() in onboardingUi.jsx mirrors this.
CREATE OR REPLACE FUNCTION public.onboarding_substep_lines(p_substeps jsonb)
 RETURNS TABLE(gid bigint, grp text, alt_for text, label text, key text)
 LANGUAGE sql
 IMMUTABLE
AS $function$
  WITH src AS (
    SELECT e, ord
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_substeps) = 'array' THEN p_substeps ELSE '[]'::jsonb END)
         WITH ORDINALITY AS x(e, ord)
  ),
  lines AS (
    SELECT 0::bigint AS gid, NULL::text AS grp, NULL::text AS alt_for, e #>> '{}' AS label, ord, 0::bigint AS ix
    FROM src WHERE jsonb_typeof(e) = 'string'
    UNION ALL
    SELECT ord, e ->> 'group', NULLIF(e ->> 'alt_for', ''), i #>> '{}', ord, ix
    FROM src,
         LATERAL jsonb_array_elements(
           CASE WHEN jsonb_typeof(e) = 'object' AND jsonb_typeof(e -> 'items') = 'array'
                THEN e -> 'items' ELSE '[]'::jsonb END) WITH ORDINALITY AS y(i, ix)
    WHERE jsonb_typeof(i) = 'string'
  )
  SELECT gid, grp, alt_for, label,
         CASE WHEN count(*) OVER (PARTITION BY label) > 1
              THEN COALESCE(grp, '') || ' › ' || label ELSE label END
  FROM lines
  ORDER BY ord, ix;
$function$;

CREATE OR REPLACE FUNCTION public.onboarding_substep_keys(p_substeps jsonb)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT COALESCE(array_agg(key), ARRAY[]::text[]) FROM public.onboarding_substep_lines(p_substeps);
$function$;

REVOKE EXECUTE ON FUNCTION public.onboarding_substep_lines(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.onboarding_substep_lines(jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.onboarding_substep_keys(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.onboarding_substep_keys(jsonb) TO authenticated, service_role;

-- Lines still open, by the text each is ticked under. A line with an archived
-- alternative counts as done when every line of that alternative is ticked.
CREATE OR REPLACE FUNCTION public.onboarding_substeps_missing(p_substeps jsonb, p_done jsonb)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
  WITH l AS (SELECT * FROM public.onboarding_substep_lines(p_substeps)),
  done AS (
    SELECT public.onboarding_substep_labels(
             CASE WHEN jsonb_typeof(p_done) = 'array' THEN p_done ELSE '[]'::jsonb END) AS d
  ),
  alts AS (
    SELECT gid, alt_for, array_agg(key) AS keys FROM l WHERE alt_for IS NOT NULL GROUP BY gid, alt_for
  )
  SELECT count(*)::int
  FROM l, done
  WHERE l.alt_for IS NULL
    AND NOT (l.key = ANY (done.d))
    AND NOT EXISTS (SELECT 1 FROM alts a WHERE a.alt_for = l.label AND a.keys <@ done.d);
$function$;

-- Ticks made before this change were made on the bare line and covered every
-- heading it sat under. Carry each one onto every heading it covered.
UPDATE public.team_onboarding_steps s
SET substeps_done = (
  SELECT jsonb_agg(DISTINCT y.x)
  FROM (
    SELECT d AS x FROM jsonb_array_elements_text(s.substeps_done) d
    WHERE NOT EXISTS (SELECT 1 FROM public.onboarding_substep_lines(s.substeps) ln WHERE ln.label = d AND ln.key <> d)
    UNION
    SELECT ln.key FROM jsonb_array_elements_text(s.substeps_done) d
    JOIN public.onboarding_substep_lines(s.substeps) ln ON ln.label = d AND ln.key <> d
  ) y)
WHERE jsonb_typeof(s.substeps_done) = 'array'
  AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(s.substeps_done) d
              JOIN public.onboarding_substep_lines(s.substeps) ln ON ln.label = d AND ln.key <> d);

-- Template sync keeps a tick when the line is still on the card.
DO $do$
DECLARE
  v_def text := pg_get_functiondef('public.onboarding_sync_plan(uuid)'::regprocedure);
  v_old text := 'WHERE d #>> ''{}'' = ANY (public.onboarding_substep_labels(public.onboarding_fill_substeps(t.substeps, p_plan_id)))';
  v_new text := 'WHERE d #>> ''{}'' = ANY (public.onboarding_substep_keys(public.onboarding_fill_substeps(t.substeps, p_plan_id)))';
BEGIN
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'onboarding_sync_plan: expected the tick filter exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$do$;

-- A teammate's task on a team card is done when every one of their lines is ticked.
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

  -- Someone taken off the card's list loses their open task for it.
  DELETE FROM public.tasks k
  USING public.users u, public.team tm
  WHERE k.related_id = NEW.id AND k.created_by = 'onboarding_team_card' AND k.status <> 'completed'
    AND u.id = k.assigned_to AND tm.id = u.team_member_id
    AND NOT (COALESCE(public.onboarding_team_label(tm), '') = ANY (public.onboarding_substep_labels(NEW.substeps)));

  UPDATE public.tasks t
  SET status       = CASE WHEN x.done THEN 'completed' ELSE 'open' END,
      completed_at = CASE WHEN x.done THEN now() ELSE NULL END,
      updated_at   = now()
  FROM (
    SELECT k.id,
           (NEW.completed_at IS NOT NULL
            OR (EXISTS (SELECT 1 FROM public.onboarding_substep_lines(NEW.substeps) ln
                        WHERE ln.label = public.onboarding_team_label(tm))
                AND NOT EXISTS (
                  SELECT 1 FROM public.onboarding_substep_lines(NEW.substeps) ln
                  WHERE ln.label = public.onboarding_team_label(tm)
                    AND NOT (CASE WHEN jsonb_typeof(NEW.substeps_done) = 'array'
                                  THEN NEW.substeps_done ? ln.key ELSE false END)))) AS done
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

-- Closing your task on a team card ticks every one of your lines on it; reopening unticks them.
CREATE OR REPLACE FUNCTION public.task_tick_syncs_onboarding_step()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  s       record;
  v_label text;
  v_keys  text[];
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

  -- Team card: this task is one teammate's own lines on it.
  IF s.owner_kind = 'team' THEN
    SELECT public.onboarding_team_label(tm) INTO v_label
    FROM public.users u JOIN public.team tm ON tm.id = u.team_member_id
    WHERE u.id = NEW.assigned_to;
    SELECT COALESCE(array_agg(ln.key), ARRAY[]::text[]) INTO v_keys
    FROM public.onboarding_substep_lines(s.substeps) ln WHERE ln.label = v_label;
    IF v_label IS NULL OR cardinality(v_keys) = 0 THEN
      RETURN NEW;
    END IF;
    IF NEW.status = 'completed' THEN
      UPDATE public.team_onboarding_steps
      SET substeps_done = COALESCE(CASE WHEN jsonb_typeof(substeps_done) = 'array' THEN substeps_done END, '[]'::jsonb)
                          || COALESCE((SELECT jsonb_agg(k) FROM unnest(v_keys) k
                                       WHERE NOT (COALESCE(CASE WHEN jsonb_typeof(substeps_done) = 'array'
                                                                THEN substeps_done END, '[]'::jsonb) ? k)), '[]'::jsonb),
          updated_at = now()
      WHERE id = s.id
        AND NOT (COALESCE(CASE WHEN jsonb_typeof(substeps_done) = 'array' THEN substeps_done END, '[]'::jsonb) ?& v_keys);
      UPDATE public.team_onboarding_steps
      SET completed_at = now(), completed_by = COALESCE(completed_by, NEW.assigned_to), updated_at = now()
      WHERE id = s.id AND completed_at IS NULL
        AND public.onboarding_substeps_missing(substeps, substeps_done) = 0;
    ELSE
      UPDATE public.team_onboarding_steps
      SET substeps_done = substeps_done - v_keys,
          completed_at  = NULL,
          completed_by  = NULL,
          updated_at    = now()
      WHERE id = s.id AND jsonb_typeof(substeps_done) = 'array' AND substeps_done ?| v_keys;
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

-- ── 2. Admins do not confirm the handbook ─────────────────────────────────
-- Who has to confirm the handbook: everyone except the owner and admin logins
-- (Peter 2026-10-06). The one rule; the status view and the publish trigger use it.
CREATE OR REPLACE FUNCTION public.handbook_ack_needed(p_team_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT NOT EXISTS (
    SELECT 1 FROM public.team t JOIN public.users u ON u.id = t.user_id
    WHERE t.id = p_team_id AND u.role IN ('owner', 'admin'));
$function$;

REVOKE EXECUTE ON FUNCTION public.handbook_ack_needed(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handbook_ack_needed(uuid) TO authenticated, service_role;

DO $do$
DECLARE
  v_def text := pg_get_viewdef('public.v_team_form_status'::regclass, true);
  v_old text := 'WHEN f.form_type = ''handbook_ack''::text THEN
            CASE
                WHEN r.id IS NULL';
  v_new text := 'WHEN f.form_type = ''handbook_ack''::text THEN
            CASE
                WHEN NOT handbook_ack_needed(t.id) THEN ''waived''::text
                WHEN r.id IS NULL';
BEGIN
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'v_team_form_status: expected the handbook branch exactly once';
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_team_form_status WITH (security_invoker = true) AS ' || replace(v_def, v_old, v_new);
END
$do$;

CREATE OR REPLACE FUNCTION public.tg_handbook_version_published()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.doc_type = 'handbook' AND NEW.is_current IS TRUE THEN
    INSERT INTO public.team_form_requirements
      (team_member_id, form_type, due_date, cycle_months, status)
    SELECT t.id, 'handbook_ack', COALESCE(NEW.effective_date, CURRENT_DATE), NULL, 'due'
      FROM public.team t
     WHERE t.agency_id = NEW.agency_id AND t.is_active IS TRUE
       AND COALESCE(t.is_test_user,false) = false
       AND public.handbook_ack_needed(t.id)
    ON CONFLICT (team_member_id, form_type) DO UPDATE SET
      due_date = COALESCE(NEW.effective_date, CURRENT_DATE),
      status   = 'due',
      updated_at = now();
  END IF;
  RETURN NEW;
END;
$function$;

-- ── 3. Handbook changes make a new version; the team reads only what changed ──
ALTER TABLE public.form_documents ADD COLUMN IF NOT EXISTS snapshot jsonb;

-- Every live handbook page as it reads right now: page id -> title, link id, order, text.
CREATE OR REPLACE FUNCTION public.handbook_snapshot(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(jsonb_object_agg(m.id::text, jsonb_build_object(
           'title', m.title, 'page', m.confluence_page_id, 'sort', m.sort_order,
           'content', COALESCE(m.content, ''))), '{}'::jsonb)
  FROM public.manuals m
  WHERE m.agency_id = p_agency_id AND m.manual_type = 'handbook' AND m.is_active IS TRUE;
$function$;

-- Any edit to the handbook pages. If nobody has confirmed the current version
-- yet, the edit joins it. If someone has, the edit starts a new version and
-- everyone who needs to confirms again (tg_handbook_version_published).
CREATE OR REPLACE FUNCTION public.tg_handbook_pages_changed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  cur  public.form_documents;
  snap jsonb;
BEGIN
  SELECT * INTO cur FROM public.form_documents
  WHERE doc_type = 'handbook' AND is_current IS TRUE
  ORDER BY version DESC LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;

  snap := public.handbook_snapshot(cur.agency_id);
  IF cur.snapshot IS NOT DISTINCT FROM snap THEN RETURN NULL; END IF;

  IF cur.snapshot IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.team_form_submissions s
       WHERE s.agency_id = cur.agency_id AND s.form_type = 'handbook_ack'
         AND s.cycle_key = 'v' || cur.version AND s.status IN ('submitted', 'locked')) THEN
    UPDATE public.form_documents SET snapshot = snap WHERE id = cur.id;
    RETURN NULL;
  END IF;

  UPDATE public.form_documents SET is_current = false WHERE id = cur.id;
  INSERT INTO public.form_documents (agency_id, doc_type, version, title, effective_date, is_current, snapshot)
  VALUES (cur.agency_id, 'handbook', cur.version + 1, cur.title, CURRENT_DATE, true, snap);
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_handbook_pages_changed ON public.manuals;
CREATE TRIGGER trg_handbook_pages_changed
  AFTER INSERT OR UPDATE OR DELETE ON public.manuals
  FOR EACH STATEMENT EXECUTE FUNCTION public.tg_handbook_pages_changed();

-- What changed in the handbook since a version: per page, the paragraphs that
-- are new or reworded, and the ones taken out. Paragraphs are split on blank lines.
CREATE OR REPLACE FUNCTION public.handbook_changes(p_from_version integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH a AS (
    SELECT COALESCE((SELECT snapshot FROM public.form_documents
                     WHERE doc_type = 'handbook' AND version = p_from_version LIMIT 1), '{}'::jsonb) AS s
  ),
  b AS (
    SELECT COALESCE((SELECT snapshot FROM public.form_documents
                     WHERE doc_type = 'handbook' AND is_current IS TRUE ORDER BY version DESC LIMIT 1), '{}'::jsonb) AS s
  ),
  ids AS (
    SELECT jsonb_object_keys(b.s) AS id FROM b
    UNION SELECT jsonb_object_keys(a.s) FROM a
  ),
  pages AS (
    SELECT ids.id,
           COALESCE(b.s -> ids.id ->> 'title', a.s -> ids.id ->> 'title') AS title,
           COALESCE(b.s -> ids.id ->> 'page', a.s -> ids.id ->> 'page') AS page,
           COALESCE((b.s -> ids.id ->> 'sort')::int, (a.s -> ids.id ->> 'sort')::int, 0) AS sort,
           b.s -> ids.id IS NULL AS removed_page,
           a.s -> ids.id IS NULL AS new_page,
           COALESCE(b.s -> ids.id ->> 'content', '') AS new_c,
           COALESCE(a.s -> ids.id ->> 'content', '') AS old_c
    FROM ids, a, b
  ),
  diff AS (
    SELECT p.*,
      ARRAY(SELECT btrim(x.q, E' \n\r\t') FROM unnest(regexp_split_to_array(p.new_c, E'\n\\s*\n')) WITH ORDINALITY AS x(q, o)
            WHERE btrim(x.q, E' \n\r\t') <> ''
              AND NOT (btrim(x.q, E' \n\r\t') = ANY (SELECT btrim(y, E' \n\r\t') FROM unnest(regexp_split_to_array(p.old_c, E'\n\\s*\n')) y))
            ORDER BY x.o) AS added,
      ARRAY(SELECT btrim(x.q, E' \n\r\t') FROM unnest(regexp_split_to_array(p.old_c, E'\n\\s*\n')) WITH ORDINALITY AS x(q, o)
            WHERE btrim(x.q, E' \n\r\t') <> ''
              AND NOT (btrim(x.q, E' \n\r\t') = ANY (SELECT btrim(y, E' \n\r\t') FROM unnest(regexp_split_to_array(p.new_c, E'\n\\s*\n')) y))
            ORDER BY x.o) AS removed
    FROM pages p
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', id, 'title', title, 'page', page, 'new_page', new_page, 'removed_page', removed_page,
           'added', to_jsonb(added), 'removed', to_jsonb(removed)) ORDER BY sort, title), '[]'::jsonb)
  FROM diff
  WHERE cardinality(added) > 0 OR cardinality(removed) > 0;
$function$;

REVOKE EXECUTE ON FUNCTION public.handbook_changes(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handbook_changes(integer) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.handbook_snapshot(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handbook_snapshot(uuid) TO authenticated, service_role;

-- The current version (v1) has no record of how the pages read. Today's pages are its baseline.
UPDATE public.form_documents SET snapshot = public.handbook_snapshot(agency_id)
WHERE doc_type = 'handbook' AND is_current IS TRUE AND snapshot IS NULL;

-- ── 4. Ongoing reads the new rules ──────────────────────────────────────────
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
             'cycle_months', l.cycle_months,
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
    -- The handbook, while the current version is unconfirmed. Someone who confirmed an
    -- earlier version reads only what changed. Owner and admin logins never get it
    -- (handbook_ack_needed, through the status view).
    SELECT jsonb_build_object(
             'kind', 'handbook', 'key', 'handbook', 'title', 'Handbook',
             'line', CASE WHEN v.last_completed_at IS NOT NULL
                          THEN 'Read what changed in the handbook and [confirm](/development?area=forms&form=handbook_ack)'
                          ELSE 'Read the handbook and [confirm](/development?area=forms&form=handbook_ack)' END,
             'due', v.due_date, 'updated', v.last_completed_at IS NOT NULL)
    FROM public.v_team_form_status v
    WHERE v.team_id = p_team_member_id
      AND v.form_type = 'handbook_ack'
      AND v.state = 'action_needed'

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
             -- On a team card, the lines that are theirs and still open, by the text each is
             -- ticked under (one per heading their name sits under).
             'mine', CASE WHEN s.owner_kind = 'team' THEN to_jsonb(ARRAY(
                       SELECT ln.key FROM public.onboarding_substep_lines(s.substeps) ln
                       WHERE ln.label = ANY (v_mine)
                         AND NOT (CASE WHEN jsonb_typeof(s.substeps_done) = 'array'
                                       THEN s.substeps_done ? ln.key ELSE false END))) END)
    FROM public.team_onboarding_steps s
    JOIN public.team_onboarding_plans p ON p.id = s.plan_id
    WHERE NOT v_tasks
      AND p.agency_id = v_t.agency_id
      AND p.team_member_id IS DISTINCT FROM p_team_member_id
      AND s.completed_at IS NULL
      AND (
            (s.owner_kind = 'team' AND EXISTS (
               SELECT 1 FROM public.onboarding_substep_lines(s.substeps) ln
               WHERE ln.label = ANY (v_mine)
                 AND NOT (CASE WHEN jsonb_typeof(s.substeps_done) = 'array'
                               THEN s.substeps_done ? ln.key ELSE false END)))
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
