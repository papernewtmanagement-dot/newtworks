-- Phase A: direct-board job posting + application infra
-- Multi-tenant-ready from birth for Phase B SaaS
-- Applied via Supabase MCP apply_migration; mirrored here per canonical path rule.

-- 1. Screener question bank (agency-scoped, code-keyed)
CREATE TABLE IF NOT EXISTS public.job_screener_questions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  question_code text NOT NULL,
  question_text text NOT NULL,
  answer_type text NOT NULL DEFAULT 'yes_no' CHECK (answer_type IN ('yes_no','multi_choice','open_text','number')),
  options jsonb,
  knockout_on text[],
  is_required boolean NOT NULL DEFAULT true,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, question_code)
);

CREATE INDEX IF NOT EXISTS idx_job_screener_questions_agency
  ON public.job_screener_questions(agency_id) WHERE is_active = true;

-- 2. Job postings
CREATE TABLE IF NOT EXISTS public.job_postings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  posting_slug text NOT NULL,
  job_title text NOT NULL,
  employment_type text NOT NULL CHECK (employment_type IN ('full_time','part_time','contract','temporary')),
  location_mode text NOT NULL CHECK (location_mode IN ('onsite','remote','hybrid')),
  city text,
  state text,
  postal_code text,
  country text NOT NULL DEFAULT 'US',
  salary_min numeric,
  salary_max numeric,
  salary_currency text NOT NULL DEFAULT 'USD',
  salary_period text CHECK (salary_period IN ('year','month','week','day','hour')),
  description_body text NOT NULL,
  screener_codes text[] NOT NULL DEFAULT '{}',
  is_active boolean NOT NULL DEFAULT true,
  publish_to_indeed boolean NOT NULL DEFAULT true,
  publish_to_ziprecruiter boolean NOT NULL DEFAULT true,
  publish_to_careers_page boolean NOT NULL DEFAULT true,
  external_indeed_id text,
  external_zip_id text,
  first_published_at timestamptz,
  last_published_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, posting_slug)
);

CREATE INDEX IF NOT EXISTS idx_job_postings_agency_active
  ON public.job_postings(agency_id) WHERE is_active = true;

-- 3. Raw applications landing zone
CREATE TABLE IF NOT EXISTS public.job_applications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  job_posting_id uuid REFERENCES public.job_postings(id) ON DELETE SET NULL,
  source text NOT NULL CHECK (source IN ('indeed_direct','ziprecruiter_direct','careers_page','manual')),
  received_at timestamptz NOT NULL DEFAULT now(),
  raw_payload jsonb,
  first_name text,
  last_name text,
  email text,
  phone text,
  resume_url text,
  resume_text text,
  cover_letter_text text,
  screener_answers jsonb NOT NULL DEFAULT '{}',
  knockout_reason text,
  hiring_candidate_id uuid REFERENCES public.hiring_candidates(id) ON DELETE SET NULL,
  routed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_job_applications_agency_received
  ON public.job_applications(agency_id, received_at DESC);
CREATE INDEX IF NOT EXISTS idx_job_applications_posting
  ON public.job_applications(job_posting_id);
CREATE INDEX IF NOT EXISTS idx_job_applications_candidate
  ON public.job_applications(hiring_candidate_id) WHERE hiring_candidate_id IS NOT NULL;

-- 4. Extend hiring_candidates
ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS source_channel text,
  ADD COLUMN IF NOT EXISTS job_posting_id uuid REFERENCES public.job_postings(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_hiring_candidates_source
  ON public.hiring_candidates(agency_id, source_channel) WHERE source_channel IS NOT NULL;

-- 5. updated_at trigger
CREATE OR REPLACE FUNCTION public.tg_set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS trg_job_screener_questions_updated_at ON public.job_screener_questions;
CREATE TRIGGER trg_job_screener_questions_updated_at
  BEFORE UPDATE ON public.job_screener_questions
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

DROP TRIGGER IF EXISTS trg_job_postings_updated_at ON public.job_postings;
CREATE TRIGGER trg_job_postings_updated_at
  BEFORE UPDATE ON public.job_postings
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

DROP TRIGGER IF EXISTS trg_job_applications_updated_at ON public.job_applications;
CREATE TRIGGER trg_job_applications_updated_at
  BEFORE UPDATE ON public.job_applications
  FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

-- 6. RLS
ALTER TABLE public.job_screener_questions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.job_postings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.job_applications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS jsq_agency_all ON public.job_screener_questions;
CREATE POLICY jsq_agency_all ON public.job_screener_questions
  FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

DROP POLICY IF EXISTS jp_agency_all ON public.job_postings;
CREATE POLICY jp_agency_all ON public.job_postings
  FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

DROP POLICY IF EXISTS jp_public_active ON public.job_postings;
CREATE POLICY jp_public_active ON public.job_postings
  FOR SELECT TO anon
  USING (is_active = true AND publish_to_careers_page = true);

DROP POLICY IF EXISTS ja_agency_all ON public.job_applications;
CREATE POLICY ja_agency_all ON public.job_applications
  FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

DROP POLICY IF EXISTS ja_anon_insert ON public.job_applications;
CREATE POLICY ja_anon_insert ON public.job_applications
  FOR INSERT TO anon
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- 7. Grants
GRANT SELECT ON public.job_postings TO anon;
GRANT SELECT ON public.job_screener_questions TO anon;
GRANT INSERT ON public.job_applications TO anon;
GRANT ALL ON public.job_postings, public.job_screener_questions, public.job_applications TO authenticated;

COMMENT ON TABLE public.job_postings IS 'Phase A: direct-to-board job postings. Multi-tenant-ready for Phase B SaaS.';
COMMENT ON TABLE public.job_screener_questions IS 'Screener question bank; postings reference by screener_codes[] array.';
COMMENT ON TABLE public.job_applications IS 'Raw applications from Indeed webhook, ZipRecruiter webhook, or careers page. Route to hiring_candidates after knockout check.';
