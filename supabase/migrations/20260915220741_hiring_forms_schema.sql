-- Digital hiring forms. Everything hangs off team.id as a child table so the
-- history survives: acknowledgments recur, and the non-compete pins a version.

CREATE TABLE IF NOT EXISTS public.form_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  doc_type text NOT NULL CHECK (doc_type IN ('non_compete','handbook')),
  version integer NOT NULL,
  title text NOT NULL,
  body text,
  effective_date date NOT NULL DEFAULT CURRENT_DATE,
  is_current boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS form_documents_type_version_uq
  ON public.form_documents (agency_id, doc_type, version);
CREATE UNIQUE INDEX IF NOT EXISTS form_documents_one_current_uq
  ON public.form_documents (agency_id, doc_type) WHERE is_current;

CREATE TABLE IF NOT EXISTS public.team_form_submissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  team_id uuid NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,
  form_type text NOT NULL CHECK (form_type IN
    ('combined_onboarding','non_compete','annual_certification','handbook_ack','i9')),
  -- one live row per person per form per cycle. '' for one-time forms,
  -- the year for the annual certification, 'v3' for a versioned document.
  cycle_key text NOT NULL DEFAULT '',
  document_id uuid REFERENCES public.form_documents(id),
  status text NOT NULL DEFAULT 'not_started' CHECK (status IN
    ('not_started','in_progress','submitted','locked','superseded')),
  data jsonb NOT NULL DEFAULT '{}'::jsonb,
  employee_submitted_at timestamptz,
  employer_section jsonb,
  employer_completed_by uuid REFERENCES public.team(id),
  employer_completed_at timestamptz,
  locked_at timestamptz,
  retention_until date,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS team_form_submissions_live_uq
  ON public.team_form_submissions (team_id, form_type, cycle_key);
CREATE INDEX IF NOT EXISTS team_form_submissions_team_idx
  ON public.team_form_submissions (team_id, form_type);

-- Social Security number and bank details live here and ONLY here, so the purge
-- after SurePayroll entry is one delete that cannot take the submission with it.
CREATE TABLE IF NOT EXISTS public.team_form_secure (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  submission_id uuid NOT NULL UNIQUE
    REFERENCES public.team_form_submissions(id) ON DELETE CASCADE,
  agency_id uuid NOT NULL,
  ssn text,
  banks jsonb NOT NULL DEFAULT '[]'::jsonb,
  entered_in_surepayroll_at timestamptz,
  purged_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.team_form_edits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  submission_id uuid NOT NULL
    REFERENCES public.team_form_submissions(id) ON DELETE CASCADE,
  agency_id uuid NOT NULL,
  field_path text NOT NULL,
  old_value text,
  new_value text,
  reason text,
  edited_by uuid REFERENCES public.team(id),
  edited_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS team_form_edits_submission_idx
  ON public.team_form_edits (submission_id, edited_at DESC);

ALTER TABLE public.form_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.team_form_submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.team_form_secure ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.team_form_edits ENABLE ROW LEVEL SECURITY;
