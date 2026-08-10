-- Financial Literacy Course Gradebook (Newtworks)
-- Agency-scoped, owner-only access. Minors' data minimized per spec.

CREATE TABLE IF NOT EXISTS public.course_students (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id         uuid NOT NULL,
  school_year       text NOT NULL,
  display_name      text NOT NULL,
  grade_level       text CHECK (grade_level IS NULL OR grade_level IN ('sophomore','junior','senior')),
  is_active         boolean NOT NULL DEFAULT true,
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, school_year, display_name)
);

CREATE TABLE IF NOT EXISTS public.course_sessions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id         uuid NOT NULL,
  school_year       text NOT NULL,
  session_code      text NOT NULL,
  session_date      date NOT NULL,
  semester          text NOT NULL CHECK (semester IN ('fall','spring')),
  title             text,
  was_held          boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, school_year, session_code)
);

CREATE TABLE IF NOT EXISTS public.course_grade_items (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id         uuid NOT NULL,
  school_year       text NOT NULL,
  student_id        uuid NOT NULL REFERENCES public.course_students(id) ON DELETE CASCADE,
  item_ref          text NOT NULL,
  item_title        text,
  weight_category   text NOT NULL CHECK (weight_category IN ('project','capstone')),
  assigned_date     date,
  due_date          date,
  score             numeric CHECK (score IS NULL OR (score >= 0 AND score <= 100)),
  feedback          text,
  graded_at         timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, school_year, student_id, item_ref)
);

CREATE TABLE IF NOT EXISTS public.course_participation (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id          uuid NOT NULL,
  student_id         uuid NOT NULL REFERENCES public.course_students(id) ON DELETE CASCADE,
  session_id         uuid NOT NULL REFERENCES public.course_sessions(id) ON DELETE CASCADE,
  on_time            boolean,
  brought_bible      boolean,
  took_notes         boolean,
  contributed        boolean,
  homework_complete  boolean,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, student_id, session_id)
);

CREATE INDEX IF NOT EXISTS idx_course_students_year ON public.course_students(agency_id, school_year);
CREATE INDEX IF NOT EXISTS idx_course_sessions_year ON public.course_sessions(agency_id, school_year);
CREATE INDEX IF NOT EXISTS idx_course_sessions_date ON public.course_sessions(agency_id, session_date);
CREATE INDEX IF NOT EXISTS idx_course_grade_items_student ON public.course_grade_items(agency_id, student_id);
CREATE INDEX IF NOT EXISTS idx_course_participation_session ON public.course_participation(agency_id, session_id);
CREATE INDEX IF NOT EXISTS idx_course_participation_student ON public.course_participation(agency_id, student_id);

ALTER TABLE public.course_students ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.course_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.course_grade_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.course_participation ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS owner_all_course_students ON public.course_students;
CREATE POLICY owner_all_course_students ON public.course_students
  FOR ALL TO authenticated
  USING (current_app_user_role() = 'owner')
  WITH CHECK (current_app_user_role() = 'owner');

DROP POLICY IF EXISTS owner_all_course_sessions ON public.course_sessions;
CREATE POLICY owner_all_course_sessions ON public.course_sessions
  FOR ALL TO authenticated
  USING (current_app_user_role() = 'owner')
  WITH CHECK (current_app_user_role() = 'owner');

DROP POLICY IF EXISTS owner_all_course_grade_items ON public.course_grade_items;
CREATE POLICY owner_all_course_grade_items ON public.course_grade_items
  FOR ALL TO authenticated
  USING (current_app_user_role() = 'owner')
  WITH CHECK (current_app_user_role() = 'owner');

DROP POLICY IF EXISTS owner_all_course_participation ON public.course_participation;
CREATE POLICY owner_all_course_participation ON public.course_participation
  FOR ALL TO authenticated
  USING (current_app_user_role() = 'owner')
  WITH CHECK (current_app_user_role() = 'owner');

GRANT SELECT, INSERT, UPDATE, DELETE ON public.course_students TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.course_sessions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.course_grade_items TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.course_participation TO authenticated;

CREATE OR REPLACE VIEW public.v_course_grades AS
WITH participation_calc AS (
  SELECT
    cp.agency_id,
    cp.student_id,
    cs.school_year,
    SUM(
      (CASE WHEN cp.on_time IS NOT NULL THEN 1 ELSE 0 END) +
      (CASE WHEN cp.brought_bible IS NOT NULL THEN 1 ELSE 0 END) +
      (CASE WHEN cp.took_notes IS NOT NULL THEN 1 ELSE 0 END) +
      (CASE WHEN cp.contributed IS NOT NULL THEN 1 ELSE 0 END) +
      (CASE WHEN cp.homework_complete IS NOT NULL THEN 1 ELSE 0 END)
    ) FILTER (WHERE cs.was_held = true) AS checks_possible,
    SUM(
      (CASE WHEN cp.on_time IS TRUE THEN 1 ELSE 0 END) +
      (CASE WHEN cp.brought_bible IS TRUE THEN 1 ELSE 0 END) +
      (CASE WHEN cp.took_notes IS TRUE THEN 1 ELSE 0 END) +
      (CASE WHEN cp.contributed IS TRUE THEN 1 ELSE 0 END) +
      (CASE WHEN cp.homework_complete IS TRUE THEN 1 ELSE 0 END)
    ) FILTER (WHERE cs.was_held = true) AS checks_earned
  FROM public.course_participation cp
  JOIN public.course_sessions cs ON cs.id = cp.session_id
  WHERE cs.was_held = true
  GROUP BY cp.agency_id, cp.student_id, cs.school_year
),
project_calc AS (
  SELECT
    agency_id, student_id, school_year,
    AVG(score) FILTER (WHERE weight_category = 'project' AND score IS NOT NULL) AS projects_pct,
    COUNT(*) FILTER (WHERE weight_category = 'project') AS projects_total_count,
    COUNT(*) FILTER (WHERE weight_category = 'project' AND score IS NOT NULL) AS projects_graded_count,
    MAX(score) FILTER (WHERE weight_category = 'capstone') AS capstone_pct,
    BOOL_OR(weight_category = 'capstone' AND score IS NOT NULL) AS capstone_graded
  FROM public.course_grade_items
  GROUP BY agency_id, student_id, school_year
)
SELECT
  s.id AS student_id,
  s.agency_id,
  s.school_year,
  s.display_name,
  s.grade_level,
  s.is_active,
  CASE WHEN pc.checks_possible > 0
       THEN ROUND(100.0 * pc.checks_earned / pc.checks_possible, 1)
       ELSE NULL END AS participation_pct,
  pc.checks_earned,
  pc.checks_possible,
  ROUND(gc.projects_pct, 1) AS projects_pct,
  COALESCE(gc.projects_graded_count, 0) AS projects_graded_count,
  COALESCE(gc.projects_total_count, 0) AS projects_total_count,
  CASE WHEN gc.capstone_graded THEN gc.capstone_pct ELSE NULL END AS capstone_pct,
  ROUND(
    (
      COALESCE(CASE WHEN pc.checks_possible > 0 THEN (100.0 * pc.checks_earned / pc.checks_possible) * 0.40 ELSE 0 END, 0) +
      COALESCE(CASE WHEN gc.projects_graded_count > 0 THEN gc.projects_pct * 0.45 ELSE 0 END, 0) +
      COALESCE(CASE WHEN gc.capstone_graded THEN gc.capstone_pct * 0.15 ELSE 0 END, 0)
    )
    /
    NULLIF(
      (CASE WHEN pc.checks_possible > 0 THEN 0.40 ELSE 0 END) +
      (CASE WHEN gc.projects_graded_count > 0 THEN 0.45 ELSE 0 END) +
      (CASE WHEN gc.capstone_graded THEN 0.15 ELSE 0 END),
      0
    ),
    1
  ) AS current_grade_pct
FROM public.course_students s
LEFT JOIN participation_calc pc
  ON pc.student_id = s.id AND pc.school_year = s.school_year AND pc.agency_id = s.agency_id
LEFT JOIN project_calc gc
  ON gc.student_id = s.id AND gc.school_year = s.school_year AND gc.agency_id = s.agency_id;
