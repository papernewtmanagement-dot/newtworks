-- Family: one timers row (shower + burpees), burpee points and the weekly burpee
-- champion, a gender field on kids, and school lessons worked one step at a time.
-- Peter's spec: session note "2026-09-22 (late) — Family: handoff for timers row,
-- burpee points, school steps". Open calls (task 15bfbe32) are built as:
-- the best tier counts (not the sum), no fine for a slow burpee run, only parents
-- cancel a timer, and the burpee timer does not check off the Burpees chore.

-- 1. Kids: gender, used to pick King or Queen for the burpee champion.
ALTER TABLE public.family_kids ADD COLUMN IF NOT EXISTS gender text;
ALTER TABLE public.family_kids DROP CONSTRAINT IF EXISTS family_kids_gender_check;
ALTER TABLE public.family_kids ADD CONSTRAINT family_kids_gender_check CHECK (gender IS NULL OR gender IN ('girl', 'boy'));
UPDATE public.family_kids SET gender = 'girl'
 WHERE id IN ('e4dbcb1f-907d-4ab4-80eb-2edd3a738c2b', 'ec164fed-0a90-4942-983b-6bb1f67f0592', '3eba6625-1012-4291-9bec-ddebcdcad790');
UPDATE public.family_kids SET gender = 'boy'
 WHERE id IN ('1a8f1d26-7116-4ee9-b4f7-aa6cf91f4692', 'b1aab3a6-543f-4253-87c5-aa1d7fe3edce');

-- 2. Burpee timer length.
ALTER TABLE public.family_settings ADD COLUMN IF NOT EXISTS burpee_minutes smallint NOT NULL DEFAULT 15;

-- 3. One table for every timer. The shower table had no rows; it becomes family_timers.
ALTER TABLE public.family_showers RENAME TO family_timers;
ALTER TABLE public.family_timers RENAME CONSTRAINT family_showers_pkey TO family_timers_pkey;
ALTER TABLE public.family_timers RENAME CONSTRAINT family_showers_agency_id_fkey TO family_timers_agency_id_fkey;
ALTER TABLE public.family_timers RENAME CONSTRAINT family_showers_kid_id_fkey TO family_timers_kid_id_fkey;
ALTER TABLE public.family_timers RENAME CONSTRAINT family_showers_ledger_id_fkey TO family_timers_ledger_id_fkey;
ALTER POLICY family_showers_family_read ON public.family_timers RENAME TO family_timers_family_read;
ALTER POLICY family_showers_parents_all ON public.family_timers RENAME TO family_timers_parents_all;
ALTER TABLE public.family_timers ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'shower';
ALTER TABLE public.family_timers ALTER COLUMN kind DROP DEFAULT;
ALTER TABLE public.family_timers DROP CONSTRAINT IF EXISTS family_timers_kind_check;
ALTER TABLE public.family_timers ADD CONSTRAINT family_timers_kind_check CHECK (kind IN ('shower', 'burpees'));
-- Burpees owed for the set the run was for, snapshotted at start (see family_burpee_counts).
ALTER TABLE public.family_timers ADD COLUMN IF NOT EXISTS burpee_count integer;
DROP INDEX IF EXISTS public.family_showers_one_running;
CREATE UNIQUE INDEX IF NOT EXISTS family_timers_one_running ON public.family_timers (kid_id, kind) WHERE ended_at IS NULL;

-- 4. Burpee champion titles. One word a week, in order; pairs follow the kid's gender.
CREATE TABLE IF NOT EXISTS public.family_burpee_titles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid REFERENCES public.agency(id),
  boy text NOT NULL,
  girl text NOT NULL,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.family_burpee_titles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS family_burpee_titles_family_read ON public.family_burpee_titles;
CREATE POLICY family_burpee_titles_family_read ON public.family_burpee_titles FOR SELECT
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND ((SELECT public.auth_is_family()) OR (SELECT public.family_is_parent())));
DROP POLICY IF EXISTS family_burpee_titles_parents_all ON public.family_burpee_titles;
CREATE POLICY family_burpee_titles_parents_all ON public.family_burpee_titles FOR ALL
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()))
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()));
INSERT INTO public.family_burpee_titles (boy, girl, sort_order)
SELECT v.boy, v.girl, v.n
  FROM (VALUES
    (1, 'King', 'Queen'), (2, 'Master', 'Master'), (3, 'Supreme', 'Supreme'), (4, 'Leader', 'Leader'),
    (5, 'Champion', 'Champion'), (6, 'Emperor', 'Empress'), (7, 'Legend', 'Legend'), (8, 'Boss', 'Boss'),
    (9, 'Titan', 'Titan'), (10, 'Prince', 'Princess'), (11, 'Captain', 'Captain'), (12, 'Machine', 'Machine'),
    (13, 'Wizard', 'Wizard'), (14, 'Hero', 'Hero'), (15, 'Chief', 'Chief'), (16, 'Duke', 'Duchess'),
    (17, 'Rocket', 'Rocket'), (18, 'Dynamo', 'Dynamo'), (19, 'Ace', 'Ace'), (20, 'Monarch', 'Monarch'),
    (21, 'Superstar', 'Superstar'), (22, 'Commander', 'Commander'), (23, 'Tornado', 'Tornado'), (24, 'Maestro', 'Maestro')
  ) AS v(n, boy, girl)
 WHERE NOT EXISTS (SELECT 1 FROM public.family_burpee_titles);

-- 5. Timers. Which timers a kid has, and the one running of each kind.
-- Burpees: any kid with a Burpees chore active today; shows all day.
-- Shower: kids with shower minutes set; the screen shows it from 5 pm Central (shows_from).
CREATE OR REPLACE FUNCTION public.family_timer_list(p_kid_id uuid)
RETURNS TABLE(kind text, icon text, minutes integer, shows_from time, running_id uuid, started_at timestamptz, limit_seconds integer)
LANGUAGE sql STABLE SET search_path = public AS $$
  WITH today AS (SELECT (now() AT TIME ZONE 'America/Chicago')::date AS d),
  kinds AS (
    SELECT 'burpees'::text AS kind, '💪'::text AS icon, s.burpee_minutes::int AS minutes, NULL::time AS shows_from, 1 AS ord
      FROM public.family_kids k
      JOIN public.family_settings s ON s.agency_id = k.agency_id
      CROSS JOIN today
     WHERE k.id = p_kid_id AND k.is_active
       AND EXISTS (SELECT 1 FROM public.family_chores c
                    WHERE c.kid_id = k.id AND c.is_burpees
                      AND (c.active_from IS NULL OR c.active_from <= today.d)
                      AND (c.active_to IS NULL OR c.active_to >= today.d))
    UNION ALL
    SELECT 'shower', '🚿', k.shower_minutes::int, time '17:00', 2
      FROM public.family_kids k
     WHERE k.id = p_kid_id AND k.is_active AND k.shower_minutes IS NOT NULL
  )
  SELECT x.kind, x.icon, x.minutes, x.shows_from, t.id, t.started_at, t.limit_seconds
    FROM kinds x
    LEFT JOIN public.family_timers t ON t.kid_id = p_kid_id AND t.kind = x.kind AND t.ended_at IS NULL
   ORDER BY x.ord;
$$;

CREATE OR REPLACE FUNCTION public.family_timer_start(p_kid_id uuid, p_kind text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_min int; v_count int; v_today date := (now() AT TIME ZONE 'America/Chicago')::date; v_row public.family_timers;
BEGIN
  IF NOT (public.family_is_parent() OR public.auth_is_family()) THEN RAISE EXCEPTION 'Not allowed.'; END IF;
  SELECT l.minutes INTO v_min FROM public.family_timer_list(p_kid_id) l WHERE l.kind = p_kind;
  IF v_min IS NULL THEN RAISE EXCEPTION 'No % timer for this kid.', p_kind; END IF;
  IF p_kind = 'burpees' THEN
    -- The set this run is for: the first Burpees chore of the day not yet logged (morning, then afternoon).
    SELECT public.family_burpees_owed(c.id, v_today) INTO v_count
      FROM public.family_chores c
     WHERE c.kid_id = p_kid_id AND c.is_burpees
       AND (c.active_from IS NULL OR c.active_from <= v_today) AND (c.active_to IS NULL OR c.active_to >= v_today)
     ORDER BY EXISTS (SELECT 1 FROM public.family_chore_log g WHERE g.chore_id = c.id AND g.occurrence_date = v_today),
              CASE c.part_of_day WHEN 'morning' THEN 1 WHEN 'afternoon' THEN 2 WHEN 'evening' THEN 3 ELSE 4 END
     LIMIT 1;
  END IF;
  INSERT INTO public.family_timers (kid_id, kind, limit_seconds, burpee_count)
  VALUES (p_kid_id, p_kind, v_min * 60, v_count)
  ON CONFLICT (kid_id, kind) WHERE ended_at IS NULL DO NOTHING;
  SELECT * INTO v_row FROM public.family_timers WHERE kid_id = p_kid_id AND kind = p_kind AND ended_at IS NULL;
  RETURN to_jsonb(v_row);
END $$;

CREATE OR REPLACE FUNCTION public.family_timer_cancel(p_kid_id uuid, p_kind text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'Only a parent can cancel the timer.'; END IF;
  DELETE FROM public.family_timers WHERE kid_id = p_kid_id AND kind = p_kind AND ended_at IS NULL;
END $$;

-- 6. Burpee points. The screen shows what these return; it never works out a point.
-- A run counts only if it is no faster than 1.5 seconds a burpee. Quicker than that is a
-- double tap or a skipped set, and it must never become a personal best nobody can beat.
CREATE OR REPLACE FUNCTION public.family_burpee_counts(p_seconds integer, p_count integer)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_seconds IS NOT NULL AND p_seconds >= ceil(COALESCE(p_count, 0) * 1.5);
$$;

-- Peter 2026-09-22: inside the timer = 1 point, inside half the time = 3, faster than the
-- kid's own best before this run = 5. The best one counts, not the sum. Over the timer = 0.
-- A kid's first counted run has no best to beat.
CREATE OR REPLACE FUNCTION public.family_burpee_points(p_seconds integer, p_limit integer, p_count integer, p_prior_best integer)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_seconds IS NULL OR p_limit IS NULL OR p_seconds > p_limit THEN 0
    WHEN NOT public.family_burpee_counts(p_seconds, p_count) THEN 0
    WHEN p_prior_best IS NOT NULL AND p_seconds < p_prior_best THEN 5
    WHEN p_seconds * 2 <= p_limit THEN 3
    ELSE 1 END;
$$;

-- Every finished burpee run, with the kid's best counted time before it and its points.
CREATE OR REPLACE FUNCTION public.family_burpee_sessions()
RETURNS TABLE(id uuid, kid_id uuid, on_date date, started_at timestamptz, seconds integer, limit_seconds integer,
              burpee_count integer, counted boolean, prior_best integer, points integer)
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT s.id, s.kid_id, s.on_date, s.started_at, s.seconds, s.limit_seconds, s.burpee_count,
         public.family_burpee_counts(s.seconds, s.burpee_count), s.prior_best,
         public.family_burpee_points(s.seconds, s.limit_seconds, s.burpee_count, s.prior_best)
    FROM (SELECT t.id, t.kid_id, (t.started_at AT TIME ZONE 'America/Chicago')::date AS on_date, t.started_at,
                 t.seconds, t.limit_seconds, t.burpee_count,
                 min(t.seconds) FILTER (WHERE public.family_burpee_counts(t.seconds, t.burpee_count))
                   OVER (PARTITION BY t.kid_id ORDER BY t.started_at, t.id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prior_best
            FROM public.family_timers t
           WHERE t.kind = 'burpees' AND t.ended_at IS NOT NULL) s
   ORDER BY s.started_at;
$$;

-- Most burpee points in a finished Saturday–Friday week. Ties share it; no points, no winner.
-- The word rotates one a week in sort order from the week of 2026-09-19.
CREATE OR REPLACE FUNCTION public.family_burpee_winners(p_week_start date)
RETURNS TABLE(kid_id uuid, points integer, title text)
LANGUAGE sql STABLE SET search_path = public AS $$
  WITH w AS (SELECT public.family_week_start(p_week_start) AS ws),
  pts AS (
    SELECT s.kid_id, sum(s.points)::int AS points
      FROM public.family_burpee_sessions() s CROSS JOIN w
     WHERE s.on_date BETWEEN w.ws AND w.ws + 6
     GROUP BY s.kid_id
  ),
  top AS (SELECT max(points) AS best FROM pts),
  cnt AS (SELECT count(*)::int AS n FROM public.family_burpee_titles),
  idx AS (SELECT CASE WHEN cnt.n > 0 THEN ((((w.ws - DATE '2026-09-19') / 7) % cnt.n) + cnt.n) % cnt.n END AS i FROM w CROSS JOIN cnt),
  word AS (
    SELECT r.boy, r.girl
      FROM (SELECT boy, girl, (row_number() OVER (ORDER BY sort_order, id) - 1)::int AS rn FROM public.family_burpee_titles) r
      JOIN idx ON r.rn = idx.i
  )
  SELECT p.kid_id, p.points,
         'Burpee ' || COALESCE(CASE WHEN k.gender = 'girl' THEN wd.girl
                                    WHEN k.gender = 'boy' THEN wd.boy
                                    WHEN wd.boy = wd.girl THEN wd.boy END, 'Champion')
    FROM pts p
    JOIN top ON p.points = top.best AND top.best > 0
    JOIN public.family_kids k ON k.id = p.kid_id
    CROSS JOIN w
    LEFT JOIN word wd ON true
   WHERE (now() AT TIME ZONE 'America/Chicago')::date > w.ws + 6;
$$;

-- Per kid for one week: burpee points and timed runs, best counted time so far, and the
-- title they hold if they won the week before.
CREATE OR REPLACE FUNCTION public.family_burpee_week(p_week_start date)
RETURNS TABLE(kid_id uuid, points integer, sessions integer, best_seconds integer, champion_title text)
LANGUAGE sql STABLE SET search_path = public AS $$
  WITH w AS (SELECT public.family_week_start(p_week_start) AS ws),
  s AS (SELECT * FROM public.family_burpee_sessions()),
  wk AS (SELECT s.kid_id, sum(s.points)::int AS points, count(*)::int AS sessions
           FROM s CROSS JOIN w WHERE s.on_date BETWEEN w.ws AND w.ws + 6 GROUP BY s.kid_id),
  best AS (SELECT s.kid_id, min(s.seconds)::int AS best_seconds
             FROM s CROSS JOIN w WHERE s.counted AND s.on_date <= w.ws + 6 GROUP BY s.kid_id),
  champ AS (SELECT c.kid_id, c.title FROM w CROSS JOIN LATERAL public.family_burpee_winners(w.ws - 7) c)
  SELECT k.id, COALESCE(wk.points, 0), COALESCE(wk.sessions, 0), best.best_seconds, champ.title
    FROM public.family_kids k
    LEFT JOIN wk ON wk.kid_id = k.id
    LEFT JOIN best ON best.kid_id = k.id
    LEFT JOIN champ ON champ.kid_id = k.id
   WHERE k.is_active
   ORDER BY k.sort_order;
$$;

-- Stop: works out a shower fine, or a burpee run's points (returned for the screen to show).
CREATE OR REPLACE FUNCTION public.family_timer_stop(p_kid_id uuid, p_kind text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row public.family_timers; v_secs int; v_over int; v_fine numeric; v_rate numeric; v_ledger uuid; v_res jsonb;
BEGIN
  IF NOT (public.family_is_parent() OR public.auth_is_family()) THEN RAISE EXCEPTION 'Not allowed.'; END IF;
  SELECT * INTO v_row FROM public.family_timers WHERE kid_id = p_kid_id AND kind = p_kind AND ended_at IS NULL FOR UPDATE;
  IF v_row.id IS NULL THEN RAISE EXCEPTION 'That timer is not running.'; END IF;
  v_secs := floor(extract(epoch FROM now() - v_row.started_at))::int;
  v_over := GREATEST(0, v_secs - v_row.limit_seconds);
  -- Shower: every second over costs the per-minute fine / 60, to the cent. A given fine, so it settles at the close-out.
  IF p_kind = 'shower' THEN
    SELECT COALESCE(shower_fine_per_minute, 1.00) INTO v_rate FROM public.family_settings WHERE agency_id = v_row.agency_id;
    v_fine := round(v_over * COALESCE(v_rate, 1.00) / 60.0, 2);
    IF v_fine > 0 THEN
      INSERT INTO public.family_ledger (agency_id, kid_id, entry_date, bucket, kind, amount, note)
      VALUES (v_row.agency_id, p_kid_id, (v_row.started_at AT TIME ZONE 'America/Chicago')::date, 'spend', 'fine', -v_fine,
              'Shower ' || (v_secs / 60) || ':' || lpad((v_secs % 60)::text, 2, '0') || ' (' || (v_over / 60) || ':' || lpad((v_over % 60)::text, 2, '0') || ' over)')
      RETURNING id INTO v_ledger;
    END IF;
  END IF;
  UPDATE public.family_timers SET ended_at = now(), seconds = v_secs, over_seconds = v_over, fine = v_fine, ledger_id = v_ledger
   WHERE id = v_row.id RETURNING * INTO v_row;
  v_res := to_jsonb(v_row);
  IF p_kind = 'burpees' THEN
    SELECT v_res || jsonb_build_object('points', s.points, 'prior_best', s.prior_best, 'counted', s.counted)
      INTO v_res FROM public.family_burpee_sessions() s WHERE s.id = v_row.id;
  END IF;
  RETURN v_res;
END $$;

-- 7. School lessons, worked one step at a time. Steps = the "School Lesson" checklist.
ALTER TABLE public.family_school_lessons ADD COLUMN IF NOT EXISTS steps_done smallint NOT NULL DEFAULT 0;
UPDATE public.family_school_lessons l
   SET steps_done = COALESCE((SELECT cardinality(c.items) FROM public.family_checklists c
                               WHERE c.agency_id = l.agency_id AND c.name = 'School Lesson' ORDER BY c.created_at LIMIT 1), 0)
 WHERE l.done_at IS NOT NULL AND l.steps_done = 0;

CREATE OR REPLACE FUNCTION public.family_school_steps()
RETURNS text[] LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT COALESCE((SELECT items FROM public.family_checklists
                    WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND name = 'School Lesson'
                    ORDER BY created_at LIMIT 1), '{}'::text[]);
$$;

-- Only a parent checks the CHECK IN step (the kid talks through what they learned before the assessment).
CREATE OR REPLACE FUNCTION public.family_school_parent_step(p_step text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(btrim(p_step) ILIKE 'check in%', false);
$$;

-- One kid's lessons for one day, each with its steps, how many are done and the step to do now.
CREATE OR REPLACE FUNCTION public.family_school_day(p_kid_id uuid, p_date date)
RETURNS TABLE(id uuid, title text, sort_order integer, steps text[], steps_done integer, current_step text, parent_step boolean, done_at timestamptz)
LANGUAGE sql STABLE SET search_path = public AS $$
  WITH st AS (SELECT public.family_school_steps() AS steps)
  SELECT l.id, l.title, l.sort_order, st.steps,
         LEAST(l.steps_done, cardinality(st.steps))::int,
         CASE WHEN l.done_at IS NULL THEN st.steps[l.steps_done + 1] END,
         CASE WHEN l.done_at IS NULL THEN public.family_school_parent_step(st.steps[l.steps_done + 1]) ELSE false END,
         l.done_at
    FROM public.family_school_lessons l CROSS JOIN st
   WHERE l.kid_id = p_kid_id AND l.lesson_date = p_date
   ORDER BY l.sort_order, l.created_at;
$$;

-- Check the current step (forward) or step back one (parents only). The last step finishes the lesson.
-- The hub checks today's lessons only; a parent any day. Only a parent checks CHECK IN.
CREATE OR REPLACE FUNCTION public.family_school_step(p_id uuid, p_forward boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row public.family_school_lessons; v_parent boolean := public.family_is_parent();
        v_steps text[] := public.family_school_steps(); v_n int;
BEGIN
  IF NOT (v_parent OR public.auth_is_family()) THEN RAISE EXCEPTION 'Not allowed.'; END IF;
  SELECT * INTO v_row FROM public.family_school_lessons WHERE id = p_id FOR UPDATE;
  IF v_row.id IS NULL THEN RAISE EXCEPTION 'Lesson not found.'; END IF;
  v_n := cardinality(v_steps);
  IF p_forward THEN
    IF v_row.done_at IS NOT NULL OR v_row.steps_done >= v_n THEN RAISE EXCEPTION 'This lesson is already done.'; END IF;
    IF NOT v_parent THEN
      IF v_row.lesson_date <> (now() AT TIME ZONE 'America/Chicago')::date THEN RAISE EXCEPTION 'Only today''s lessons can be checked off.'; END IF;
      IF public.family_school_parent_step(v_steps[v_row.steps_done + 1]) THEN RAISE EXCEPTION 'A parent checks this step.'; END IF;
    END IF;
    UPDATE public.family_school_lessons
       SET steps_done = steps_done + 1,
           done_at = CASE WHEN steps_done + 1 >= v_n THEN now() END,
           done_by = CASE WHEN steps_done + 1 >= v_n THEN auth.uid() END
     WHERE id = p_id RETURNING * INTO v_row;
  ELSE
    IF NOT v_parent THEN RAISE EXCEPTION 'Only a parent can undo a step.'; END IF;
    UPDATE public.family_school_lessons
       SET steps_done = GREATEST(0, LEAST(steps_done, v_n) - 1), done_at = NULL, done_by = NULL
     WHERE id = p_id RETURNING * INTO v_row;
  END IF;
  RETURN to_jsonb(v_row);
END $$;

-- Parents save one kid's lessons for one day as explicit rows, in order: [{"id": ..., "title": ...}].
-- A row with an id keeps its step progress, even through a rename; a row without one is new;
-- a lesson left out is removed. Blank titles are skipped.
DROP FUNCTION IF EXISTS public.family_school_set_day(uuid, date, text[]);
CREATE OR REPLACE FUNCTION public.family_school_set_day(p_kid_id uuid, p_date date, p_lessons jsonb)
RETURNS integer LANGUAGE plpgsql SET search_path = public AS $$
DECLARE e jsonb; v_id uuid; v_title text; n int := 0; v_keep uuid[] := '{}';
BEGIN
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'Only a parent can set school lessons.'; END IF;
  FOR e IN SELECT value FROM jsonb_array_elements(COALESCE(p_lessons, '[]'::jsonb)) LOOP
    v_title := btrim(COALESCE(e->>'title', ''));
    CONTINUE WHEN v_title = '';
    n := n + 1;
    v_id := NULLIF(e->>'id', '')::uuid;
    IF v_id IS NOT NULL THEN
      UPDATE public.family_school_lessons SET title = v_title, sort_order = n
       WHERE id = v_id AND kid_id = p_kid_id AND lesson_date = p_date;
      IF NOT FOUND THEN v_id := NULL; END IF;
    END IF;
    IF v_id IS NULL THEN
      INSERT INTO public.family_school_lessons (kid_id, lesson_date, title, sort_order)
      VALUES (p_kid_id, p_date, v_title, n) RETURNING id INTO v_id;
    END IF;
    v_keep := v_keep || v_id;
  END LOOP;
  DELETE FROM public.family_school_lessons
   WHERE kid_id = p_kid_id AND lesson_date = p_date AND NOT (id = ANY (v_keep));
  RETURN n;
END $$;

-- 8. Replaced, one function per job: the shower-only timer calls and the one-tap lesson check.
DROP FUNCTION IF EXISTS public.family_shower_start(uuid);
DROP FUNCTION IF EXISTS public.family_shower_stop(uuid);
DROP FUNCTION IF EXISTS public.family_shower_cancel(uuid);
DROP FUNCTION IF EXISTS public.family_school_mark(uuid, boolean);

-- Guard: fail if anything still calls what was dropped or names the old table.
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public' AND p.prokind = 'f'
     AND (pg_get_functiondef(p.oid) ~ 'family_shower_(start|stop|cancel)\('
          OR pg_get_functiondef(p.oid) ~ 'family_school_mark\('
          OR pg_get_functiondef(p.oid) ~ 'family_showers\M');
  IF n > 0 THEN RAISE EXCEPTION 'Something still calls a dropped Family function (% found).', n; END IF;
END $$;

