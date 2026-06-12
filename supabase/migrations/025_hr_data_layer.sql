-- ============================================================
-- MIGRATION 025 — HR Data Layer
-- ------------------------------------------------------------
-- Adds the three-table HR enrichment layer:
--   (1) staff_assessments    — CTS Sales Profile / LSS results,
--                              including the nine primary traits,
--                              ego/empathy, LSS accuracy + speed,
--                              and competency JSONB by assessment
--                              type (cts_agent / cts_sales /
--                              cts_service_pivot / cts_service).
--   (2) staff_behavioral_notes — time-stamped observations and
--                              patterns (strength, risk_pattern,
--                              complacency, execution_gap,
--                              role_fit, fallback_role, etc.)
--                              from agent observation, call review,
--                              personality assessment, or claude
--                              conversation.
--   (3) public.staff extensions — performance_status, role_fit_score,
--                              complacency_risk, PIP dates,
--                              termination_review_date, alternate
--                              role fallback, and primary/secondary
--                              functional role columns that supplement
--                              the existing role / role_level enums.
--
-- Idempotent. Safe to re-run.
-- ============================================================


-- ----------------------------------------------------------------------
-- 1) staff_assessments
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.staff_assessments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  staff_id uuid NOT NULL REFERENCES public.staff(id) ON DELETE CASCADE,
  assessment_date date NOT NULL,
  assessment_type text NOT NULL CHECK (assessment_type IN (
    'cts_agent', 'cts_sales', 'cts_service_pivot', 'cts_service', 'other'
  )),
  -- Headline
  overall_score integer,
  overall_score_band text CHECK (overall_score_band IN ('low','low-moderate','moderate','moderate-high','high')),
  cts_only_score integer,
  cts_plus_lss_score integer,
  ego_drive_score integer,
  empathy_score integer,
  recommended_coaching_hours_min integer,
  recommended_coaching_hours_max integer,
  reliability text CHECK (reliability IN ('low','moderate','high')),
  response_distortion text CHECK (response_distortion IN ('low','moderate','high')),
  leadership_style text,  -- 'Performer' / 'Driver' / 'Analyzer' / 'Amiable' for agent assessments
  -- Nine primary traits (0-100 scale)
  deadline_motivation integer,
  recognition_drive integer,
  assertiveness integer,
  independent_spirit integer,
  analytical integer,
  compassion integer,
  self_promotion integer,
  belief_in_others integer,
  optimism integer,
  -- LSS Accuracy
  lss_math_accuracy integer,
  lss_verbal_accuracy integer,
  lss_problem_solving_accuracy integer,
  lss_total_accuracy integer,
  lss_total_ideal_min integer,
  -- LSS Speed (seconds)
  lss_math_speed_seconds integer,
  lss_verbal_speed_seconds integer,
  lss_problem_solving_speed_seconds integer,
  -- Competencies (varies by assessment type — JSONB for flexibility)
  service_competencies jsonb,
  sales_competencies jsonb,
  agent_competencies jsonb,
  -- Optional FK to the source PDF in documents table
  pdf_document_id uuid REFERENCES public.documents(id) ON DELETE SET NULL,
  -- Meta
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_staff_assessments_staff   ON public.staff_assessments(staff_id);
CREATE INDEX IF NOT EXISTS idx_staff_assessments_agency  ON public.staff_assessments(agency_id);
CREATE INDEX IF NOT EXISTS idx_staff_assessments_date    ON public.staff_assessments(assessment_date);

ALTER TABLE public.staff_assessments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "staff_assessments_select" ON public.staff_assessments;
CREATE POLICY "staff_assessments_select" ON public.staff_assessments
  FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS "staff_assessments_insert" ON public.staff_assessments;
CREATE POLICY "staff_assessments_insert" ON public.staff_assessments
  FOR INSERT TO anon, authenticated WITH CHECK (true);
DROP POLICY IF EXISTS "staff_assessments_update" ON public.staff_assessments;
CREATE POLICY "staff_assessments_update" ON public.staff_assessments
  FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "staff_assessments_delete" ON public.staff_assessments;
CREATE POLICY "staff_assessments_delete" ON public.staff_assessments
  FOR DELETE TO anon, authenticated USING (true);


-- ----------------------------------------------------------------------
-- 2) staff_behavioral_notes
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.staff_behavioral_notes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  staff_id uuid NOT NULL REFERENCES public.staff(id) ON DELETE CASCADE,
  observation_date date NOT NULL DEFAULT CURRENT_DATE,
  pattern_type text NOT NULL CHECK (pattern_type IN (
    'strength', 'weakness', 'coaching_focus', 'risk_pattern',
    'role_fit', 'execution_gap', 'complacency', 'mismatch', 'fallback_role', 'note'
  )),
  source text NOT NULL DEFAULT 'agent_observation' CHECK (source IN (
    'agent_observation', 'call_review', 'personality_assessment',
    'performance_review', 'claude_conversation', 'peer_feedback', 'other'
  )),
  observation_text text NOT NULL,
  linked_assessment_id uuid REFERENCES public.staff_assessments(id) ON DELETE SET NULL,
  is_resolved boolean NOT NULL DEFAULT false,
  resolved_date date,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_behavioral_notes_staff   ON public.staff_behavioral_notes(staff_id);
CREATE INDEX IF NOT EXISTS idx_behavioral_notes_agency  ON public.staff_behavioral_notes(agency_id);
CREATE INDEX IF NOT EXISTS idx_behavioral_notes_pattern ON public.staff_behavioral_notes(pattern_type);
CREATE INDEX IF NOT EXISTS idx_behavioral_notes_open    ON public.staff_behavioral_notes(staff_id) WHERE NOT is_resolved;

ALTER TABLE public.staff_behavioral_notes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "behavioral_notes_select" ON public.staff_behavioral_notes;
CREATE POLICY "behavioral_notes_select" ON public.staff_behavioral_notes
  FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS "behavioral_notes_insert" ON public.staff_behavioral_notes;
CREATE POLICY "behavioral_notes_insert" ON public.staff_behavioral_notes
  FOR INSERT TO anon, authenticated WITH CHECK (true);
DROP POLICY IF EXISTS "behavioral_notes_update" ON public.staff_behavioral_notes;
CREATE POLICY "behavioral_notes_update" ON public.staff_behavioral_notes
  FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "behavioral_notes_delete" ON public.staff_behavioral_notes;
CREATE POLICY "behavioral_notes_delete" ON public.staff_behavioral_notes
  FOR DELETE TO anon, authenticated USING (true);


-- ----------------------------------------------------------------------
-- 3) staff table extensions
-- ----------------------------------------------------------------------
ALTER TABLE public.staff ADD COLUMN IF NOT EXISTS performance_status text
  CHECK (performance_status IS NULL OR performance_status IN (
    'high_performer', 'on_track', 'coaching_focus', 'pip', 'at_risk', 'terminating'
  ));
ALTER TABLE public.staff ADD COLUMN IF NOT EXISTS role_fit_score integer
  CHECK (role_fit_score IS NULL OR (role_fit_score BETWEEN 1 AND 10));
ALTER TABLE public.staff ADD COLUMN IF NOT EXISTS complacency_risk text
  CHECK (complacency_risk IS NULL OR complacency_risk IN ('low','moderate','high'));
ALTER TABLE public.staff ADD COLUMN IF NOT EXISTS termination_review_date date;
ALTER TABLE public.staff ADD COLUMN IF NOT EXISTS pip_start_date date;
ALTER TABLE public.staff ADD COLUMN IF NOT EXISTS pip_end_date date;
ALTER TABLE public.staff ADD COLUMN IF NOT EXISTS alternate_role_fallback text;
ALTER TABLE public.staff ADD COLUMN IF NOT EXISTS primary_function text
  CHECK (primary_function IS NULL OR primary_function IN (
    'new_business', 'inside_sales', 'reception', 'retention', 'office_manager', 'owner', 'support'
  ));
ALTER TABLE public.staff ADD COLUMN IF NOT EXISTS secondary_function text
  CHECK (secondary_function IS NULL OR secondary_function IN (
    'new_business', 'inside_sales', 'reception', 'retention', 'office_manager', 'owner', 'support'
  ));
