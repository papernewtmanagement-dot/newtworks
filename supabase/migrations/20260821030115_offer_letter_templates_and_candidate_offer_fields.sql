-- Offer letter: a stored template with fill-in fields, plus the per-candidate
-- offer terms captured when a candidate is moved to the Offer stage.
-- Peter directive 2026-08-20.

CREATE TABLE IF NOT EXISTS public.offer_letter_templates (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id    uuid NOT NULL,
  template_key text NOT NULL,
  title        text NOT NULL,
  body_md      text NOT NULL,
  version      integer NOT NULL DEFAULT 1,
  is_active    boolean NOT NULL DEFAULT true,
  notes        text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_offer_letter_templates_key
  ON public.offer_letter_templates (agency_id, template_key);

COMMENT ON TABLE public.offer_letter_templates IS
  'Offer letter wording with double-brace fill-in fields. The offer form on the candidate page fills these in and saves the finished letter onto the candidate row.';

ALTER TABLE public.offer_letter_templates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS offer_letter_templates_auth_read   ON public.offer_letter_templates;
DROP POLICY IF EXISTS offer_letter_templates_auth_insert ON public.offer_letter_templates;
DROP POLICY IF EXISTS offer_letter_templates_auth_update ON public.offer_letter_templates;
DROP POLICY IF EXISTS offer_letter_templates_auth_delete ON public.offer_letter_templates;

CREATE POLICY offer_letter_templates_auth_read ON public.offer_letter_templates
  FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
CREATE POLICY offer_letter_templates_auth_insert ON public.offer_letter_templates
  FOR INSERT TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
CREATE POLICY offer_letter_templates_auth_update ON public.offer_letter_templates
  FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin())
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
CREATE POLICY offer_letter_templates_auth_delete ON public.offer_letter_templates
  FOR DELETE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.offer_letter_templates TO authenticated;

-- Per-candidate offer terms.
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS offer_job_title    text;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS offer_role_key     text;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS offer_pay_type     text;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS offer_pay_amount   numeric(12,2);
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS offer_pay_period   text;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS offer_start_date   date;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS offer_respond_by   date;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS offer_reports_to   text;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS offer_letter_body  text;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS offer_created_at   timestamptz;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS offer_sent_at      timestamptz;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.hiring_candidates'::regclass
      AND conname = 'hiring_candidates_offer_pay_type_check'
  ) THEN
    ALTER TABLE public.hiring_candidates
      ADD CONSTRAINT hiring_candidates_offer_pay_type_check
      CHECK (offer_pay_type IS NULL OR offer_pay_type = ANY (ARRAY['hourly'::text, 'salary'::text]));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.hiring_candidates'::regclass
      AND conname = 'hiring_candidates_offer_pay_period_check'
  ) THEN
    ALTER TABLE public.hiring_candidates
      ADD CONSTRAINT hiring_candidates_offer_pay_period_check
      CHECK (offer_pay_period IS NULL OR offer_pay_period = ANY (ARRAY['hour'::text, 'year'::text]));
  END IF;
END $$;

COMMENT ON COLUMN public.hiring_candidates.offer_letter_body IS
  'The finished offer letter after the template fields were filled in. Saved so the exact wording sent can be read back later.';

-- Pipeline order note: offer now sits BEFORE reference_check (Peter directive
-- 2026-08-20). The check constraint is a set, not an order — display order
-- lives in src/lib/hiringStages.js.
COMMENT ON COLUMN public.hiring_candidates.status IS
  'Pipeline stage. Order as displayed: applied, assessment_sent, assessed, interview, team_meet_and_greet (shown as "Meet & Greet"), offer, reference_check, hired. declined and former sit off the pipeline. email_screen retired 2026-08-12. offer and reference_check swapped 2026-08-20 — the offer is made contingent on references clearing.';
