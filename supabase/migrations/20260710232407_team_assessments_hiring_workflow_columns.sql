-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-10 23:24:07 UTC (ledger name: team_assessments_hiring_workflow_columns) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260710232407.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Extend team_assessments to be the single-source-of-truth "people row" table
-- spanning candidate → hired → archived lifecycle.

-- ── Identity ──────────────────────────────────────────────────────
ALTER TABLE public.team_assessments
  ADD COLUMN IF NOT EXISTS first_name text,
  ADD COLUMN IF NOT EXISTS last_name  text,
  ADD COLUMN IF NOT EXISTS email      text,
  ADD COLUMN IF NOT EXISTS phone      text,
  ADD COLUMN IF NOT EXISTS position   text;  -- what they applied for

-- ── Workflow ──────────────────────────────────────────────────────
ALTER TABLE public.team_assessments
  ADD COLUMN IF NOT EXISTS source            text,     -- careerplug|referral|headhunt|calibration|existing
  ADD COLUMN IF NOT EXISTS status            text,     -- see check constraint below
  ADD COLUMN IF NOT EXISTS status_updated_at timestamptz;

-- Add status check constraint (drop first in case of retry)
ALTER TABLE public.team_assessments
  DROP CONSTRAINT IF EXISTS team_assessments_status_check;
ALTER TABLE public.team_assessments
  ADD  CONSTRAINT team_assessments_status_check
  CHECK (status IS NULL OR status IN
    ('assessed','email_screen','interview','reference_check','offer','hired','archived'));

-- ── Documents ─────────────────────────────────────────────────────
ALTER TABLE public.team_assessments
  ADD COLUMN IF NOT EXISTS resume_document_id uuid REFERENCES public.documents(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS resume_url         text;

-- ── Claude analysis ───────────────────────────────────────────────
ALTER TABLE public.team_assessments
  ADD COLUMN IF NOT EXISTS claude_score    integer CHECK (claude_score IS NULL OR claude_score BETWEEN 1 AND 10),
  ADD COLUMN IF NOT EXISTS claude_summary  text,
  ADD COLUMN IF NOT EXISTS interview_focus text;

-- ── Video AMA scorecard ───────────────────────────────────────────
ALTER TABLE public.team_assessments
  ADD COLUMN IF NOT EXISTS va_personal_presence         integer CHECK (va_personal_presence IS NULL OR va_personal_presence BETWEEN 1 AND 10),
  ADD COLUMN IF NOT EXISTS va_resume_quality            integer CHECK (va_resume_quality IS NULL OR va_resume_quality BETWEEN 1 AND 10),
  ADD COLUMN IF NOT EXISTS va_honesty                   integer CHECK (va_honesty IS NULL OR va_honesty BETWEEN 1 AND 10),
  ADD COLUMN IF NOT EXISTS va_hard_work_ethic           integer CHECK (va_hard_work_ethic IS NULL OR va_hard_work_ethic BETWEEN 1 AND 10),
  ADD COLUMN IF NOT EXISTS va_personally_responsible    integer CHECK (va_personally_responsible IS NULL OR va_personally_responsible BETWEEN 1 AND 10),
  ADD COLUMN IF NOT EXISTS va_concern_for_others        integer CHECK (va_concern_for_others IS NULL OR va_concern_for_others BETWEEN 1 AND 10),
  ADD COLUMN IF NOT EXISTS va_attitude_toward_sales     integer CHECK (va_attitude_toward_sales IS NULL OR va_attitude_toward_sales BETWEEN 1 AND 10),
  ADD COLUMN IF NOT EXISTS va_willingness_to_own_products integer CHECK (va_willingness_to_own_products IS NULL OR va_willingness_to_own_products BETWEEN 1 AND 10),
  ADD COLUMN IF NOT EXISTS va_motivation_type           text,
  ADD COLUMN IF NOT EXISTS va_motivation_level          integer CHECK (va_motivation_level IS NULL OR va_motivation_level BETWEEN 1 AND 10),
  ADD COLUMN IF NOT EXISTS va_recommendation            text,
  ADD COLUMN IF NOT EXISTS va_notes                     text,
  ADD COLUMN IF NOT EXISTS va_scored_at                 timestamptz,
  ADD COLUMN IF NOT EXISTS va_scored_by                 uuid;  -- auth.users id or team_id — flexible

-- Enum checks for VA
ALTER TABLE public.team_assessments
  DROP CONSTRAINT IF EXISTS team_assessments_va_motivation_type_check;
ALTER TABLE public.team_assessments
  ADD  CONSTRAINT team_assessments_va_motivation_type_check
  CHECK (va_motivation_type IS NULL OR va_motivation_type IN ('competitive','income','duty','recognition'));

ALTER TABLE public.team_assessments
  DROP CONSTRAINT IF EXISTS team_assessments_va_recommendation_check;
ALTER TABLE public.team_assessments
  ADD  CONSTRAINT team_assessments_va_recommendation_check
  CHECK (va_recommendation IS NULL OR va_recommendation IN ('great_fit','good_fit','not_a_fit'));

-- ── Final Interview scorecard ─────────────────────────────────────
ALTER TABLE public.team_assessments
  ADD COLUMN IF NOT EXISTS fi_personal_presence           integer CHECK (fi_personal_presence IS NULL OR fi_personal_presence BETWEEN 1 AND 10),
  ADD COLUMN IF NOT EXISTS fi_resume_quality              integer CHECK (fi_resume_quality IS NULL OR fi_resume_quality BETWEEN 1 AND 10),
  ADD COLUMN IF NOT EXISTS fi_honesty                     integer CHECK (fi_honesty IS NULL OR fi_honesty BETWEEN 1 AND 10),
  ADD COLUMN IF NOT EXISTS fi_hard_work_ethic             integer CHECK (fi_hard_work_ethic IS NULL OR fi_hard_work_ethic BETWEEN 1 AND 10),
  ADD COLUMN IF NOT EXISTS fi_personally_responsible      integer CHECK (fi_personally_responsible IS NULL OR fi_personally_responsible BETWEEN 1 AND 10),
  ADD COLUMN IF NOT EXISTS fi_concern_for_others          integer CHECK (fi_concern_for_others IS NULL OR fi_concern_for_others BETWEEN 1 AND 10),
  ADD COLUMN IF NOT EXISTS fi_attitude_toward_sales       integer CHECK (fi_attitude_toward_sales IS NULL OR fi_attitude_toward_sales BETWEEN 1 AND 10),
  ADD COLUMN IF NOT EXISTS fi_willingness_to_own_products integer CHECK (fi_willingness_to_own_products IS NULL OR fi_willingness_to_own_products BETWEEN 1 AND 10),
  ADD COLUMN IF NOT EXISTS fi_motivation_type             text,
  ADD COLUMN IF NOT EXISTS fi_motivation_level            integer CHECK (fi_motivation_level IS NULL OR fi_motivation_level BETWEEN 1 AND 10),
  ADD COLUMN IF NOT EXISTS fi_recommendation              text,
  ADD COLUMN IF NOT EXISTS fi_notes                       text,
  ADD COLUMN IF NOT EXISTS fi_scored_at                   timestamptz,
  ADD COLUMN IF NOT EXISTS fi_scored_by                   uuid;

ALTER TABLE public.team_assessments
  DROP CONSTRAINT IF EXISTS team_assessments_fi_motivation_type_check;
ALTER TABLE public.team_assessments
  ADD  CONSTRAINT team_assessments_fi_motivation_type_check
  CHECK (fi_motivation_type IS NULL OR fi_motivation_type IN ('competitive','income','duty','recognition'));

ALTER TABLE public.team_assessments
  DROP CONSTRAINT IF EXISTS team_assessments_fi_recommendation_check;
ALTER TABLE public.team_assessments
  ADD  CONSTRAINT team_assessments_fi_recommendation_check
  CHECK (fi_recommendation IS NULL OR fi_recommendation IN ('great_fit','good_fit','not_a_fit'));

-- ── Reference check ───────────────────────────────────────────────
ALTER TABLE public.team_assessments
  ADD COLUMN IF NOT EXISTS rc_notes         text,
  ADD COLUMN IF NOT EXISTS rc_completed_at  timestamptz;

-- ── Final decision ────────────────────────────────────────────────
ALTER TABLE public.team_assessments
  ADD COLUMN IF NOT EXISTS final_decision  text,
  ADD COLUMN IF NOT EXISTS decision_at     timestamptz,
  ADD COLUMN IF NOT EXISTS decision_notes  text;

ALTER TABLE public.team_assessments
  DROP CONSTRAINT IF EXISTS team_assessments_final_decision_check;
ALTER TABLE public.team_assessments
  ADD  CONSTRAINT team_assessments_final_decision_check
  CHECK (final_decision IS NULL OR final_decision IN ('hire','no_hire','pending'));

-- Index on status for the kanban queries
CREATE INDEX IF NOT EXISTS idx_team_assessments_status
  ON public.team_assessments(agency_id, status)
  WHERE status IS NOT NULL;

-- Verify
SELECT COUNT(*) AS n_columns
FROM information_schema.columns
WHERE table_schema='public' AND table_name='team_assessments';
