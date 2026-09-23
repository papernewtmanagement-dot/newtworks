-- Peter 2026-09-22: each kid's school lessons listed on their day. Alvi enters the week on a parents-only tab.
CREATE TABLE IF NOT EXISTS public.family_school_lessons (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365' REFERENCES public.agency(id),
  kid_id uuid NOT NULL REFERENCES public.family_kids(id) ON DELETE CASCADE,
  lesson_date date NOT NULL,
  title text NOT NULL,
  sort_order integer NOT NULL DEFAULT 1,
  done_at timestamptz,
  done_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS family_school_lessons_kid_date ON public.family_school_lessons (kid_id, lesson_date);
ALTER TABLE public.family_school_lessons ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS family_school_family_read ON public.family_school_lessons;
CREATE POLICY family_school_family_read ON public.family_school_lessons FOR SELECT
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND ((SELECT auth_is_family()) OR (SELECT family_is_parent())));
DROP POLICY IF EXISTS family_school_parents_all ON public.family_school_lessons;
CREATE POLICY family_school_parents_all ON public.family_school_lessons FOR ALL
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT family_is_parent()))
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT family_is_parent()));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.family_school_lessons TO authenticated;

-- Parents set one kid's lessons for one day (one title per entry, in order). Lessons still listed keep
-- their done mark; lessons removed from the list are deleted.
CREATE OR REPLACE FUNCTION public.family_school_set_day(p_kid_id uuid, p_date date, p_titles text[])
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE i int; t text; n int := 0;
BEGIN
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'Only a parent can set school lessons.'; END IF;
  DELETE FROM public.family_school_lessons
   WHERE kid_id = p_kid_id AND lesson_date = p_date
     AND NOT (btrim(title) = ANY (SELECT btrim(x) FROM unnest(COALESCE(p_titles, '{}')) x WHERE btrim(x) <> ''));
  FOR i IN 1 .. COALESCE(array_length(p_titles, 1), 0) LOOP
    t := btrim(p_titles[i]);
    CONTINUE WHEN t = '';
    n := n + 1;
    UPDATE public.family_school_lessons SET sort_order = n
     WHERE kid_id = p_kid_id AND lesson_date = p_date AND btrim(title) = t;
    IF NOT FOUND THEN
      INSERT INTO public.family_school_lessons (kid_id, lesson_date, title, sort_order) VALUES (p_kid_id, p_date, t, n);
    END IF;
  END LOOP;
  RETURN n;
END $function$;
GRANT EXECUTE ON FUNCTION public.family_school_set_day(uuid, date, text[]) TO authenticated, service_role;

-- Marking a lesson done: the hub marks today's lessons done; only a parent un-marks or marks another day.
CREATE OR REPLACE FUNCTION public.family_school_mark(p_id uuid, p_done boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_row public.family_school_lessons; v_parent boolean := public.family_is_parent();
BEGIN
  IF NOT (v_parent OR public.auth_is_family()) THEN RAISE EXCEPTION 'Not allowed.'; END IF;
  SELECT * INTO v_row FROM public.family_school_lessons WHERE id = p_id;
  IF v_row.id IS NULL THEN RAISE EXCEPTION 'Lesson not found.'; END IF;
  IF NOT v_parent THEN
    IF NOT p_done THEN RAISE EXCEPTION 'Only a parent can undo that.'; END IF;
    IF v_row.lesson_date <> (now() AT TIME ZONE 'America/Chicago')::date THEN RAISE EXCEPTION 'Only today''s lessons can be checked off.'; END IF;
  END IF;
  UPDATE public.family_school_lessons
     SET done_at = CASE WHEN p_done THEN COALESCE(done_at, now()) END, done_by = CASE WHEN p_done THEN auth.uid() END
   WHERE id = p_id RETURNING * INTO v_row;
  RETURN to_jsonb(v_row);
END $function$;
REVOKE ALL ON FUNCTION public.family_school_mark(uuid, boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.family_school_mark(uuid, boolean) TO authenticated, service_role;

-- The steps from the school sheet, shown behind each lesson's info dot.
INSERT INTO public.family_checklists (agency_id, name, items)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'School Lesson',
       ARRAY['Watch video and fill out guided notes', 'Complete practice levels', 'CHECK IN to discuss what you learned', 'Take assessment']
WHERE NOT EXISTS (SELECT 1 FROM public.family_checklists WHERE name = 'School Lesson');

-- This week's schedule (September 21–25).
INSERT INTO public.family_school_lessons (kid_id, lesson_date, title, sort_order)
SELECT k.id, v.d, v.t, v.s
FROM (VALUES
  ('Becca',   DATE '2026-09-21', 'An Occurrence at Owl Creek Bridge', 1),
  ('Becca',   DATE '2026-09-21', 'Mis quehaceres', 2),
  ('Becca',   DATE '2026-09-22', 'Wrap-Up: Reflections and Translations', 1),
  ('Becca',   DATE '2026-09-23', 'Biological Importance of Water', 1),
  ('Becca',   DATE '2026-09-24', 'Constitutionalism', 1),
  ('Bella',   DATE '2026-09-21', 'Desert of Description: Adjectives and Adverbs', 1),
  ('Bella',   DATE '2026-09-21', 'Ghost', 2),
  ('Bella',   DATE '2026-09-22', 'Multiple Representations of Proportional Relationships', 1),
  ('Bella',   DATE '2026-09-23', 'Communicating Results', 1),
  ('Bella',   DATE '2026-09-24', 'The Black Death', 1),
  ('Elliott', DATE '2026-09-21', 'Fox', 1),
  ('Elliott', DATE '2026-09-21', 'Pronouns', 2),
  ('Elliott', DATE '2026-09-22', 'Rounding Numbers to the Thousands', 1),
  ('Elliott', DATE '2026-09-23', 'When Plates Collide', 1),
  ('Elliott', DATE '2026-09-24', 'Cultural Appreciation', 1)
) v(n, d, t, s)
JOIN public.family_kids k ON k.name = v.n
WHERE NOT EXISTS (SELECT 1 FROM public.family_school_lessons l WHERE l.kid_id = k.id AND l.lesson_date = v.d AND l.title = v.t);

-- Elliott's House Trash is a bigger job than 10 minutes: every can in the house, new liners, bags out.
UPDATE public.family_chores SET est_minutes = 20, pay = public.family_minutes_pay(20, agency_id)
 WHERE id = '0c0c81af-daf1-4022-9ba5-3d15d32170b2';
