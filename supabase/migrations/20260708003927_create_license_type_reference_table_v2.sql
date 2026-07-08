-- 20260708003927_create_license_type_reference_table_v2
-- Structured reference metadata per license_type. One row per license_type per agency.
-- Content sourced from admin_pages "CE & Renewals" (deleted in the same session).
-- Surfaced in the Licensing module via LicenseReferenceModal (see src/modules/Licensing.jsx).

CREATE TABLE IF NOT EXISTS public.license_type_reference (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  license_type text NOT NULL,
  display_name text,
  window_notes text,
  submission_url text,
  submission_notes text,
  discount_codes jsonb NOT NULL DEFAULT '[]'::jsonb,
  external_contacts jsonb NOT NULL DEFAULT '[]'::jsonb,
  reference_urls jsonb NOT NULL DEFAULT '[]'::jsonb,
  general_notes text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE(agency_id, license_type)
);

CREATE INDEX IF NOT EXISTS idx_license_type_reference_agency ON public.license_type_reference(agency_id);

CREATE OR REPLACE FUNCTION public.tg_license_type_reference_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := NOW(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS license_type_reference_updated_at ON public.license_type_reference;
CREATE TRIGGER license_type_reference_updated_at
BEFORE UPDATE ON public.license_type_reference
FOR EACH ROW EXECUTE FUNCTION public.tg_license_type_reference_updated_at();

ALTER TABLE public.license_type_reference ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS anon_read_license_type_reference ON public.license_type_reference;
CREATE POLICY anon_read_license_type_reference ON public.license_type_reference
  FOR SELECT USING (true);

DROP POLICY IF EXISTS authenticated_insert_license_type_reference ON public.license_type_reference;
CREATE POLICY authenticated_insert_license_type_reference ON public.license_type_reference
  FOR INSERT TO authenticated WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

DROP POLICY IF EXISTS authenticated_update_license_type_reference ON public.license_type_reference;
CREATE POLICY authenticated_update_license_type_reference ON public.license_type_reference
  FOR UPDATE TO authenticated USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

DROP POLICY IF EXISTS authenticated_delete_license_type_reference ON public.license_type_reference;
CREATE POLICY authenticated_delete_license_type_reference ON public.license_type_reference
  FOR DELETE TO authenticated USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
