-- Signature auto-gen: schema + template seed + storage bucket
-- 1. team columns (all IF NOT EXISTS, nullable, additive)
ALTER TABLE public.team
  ADD COLUMN IF NOT EXISTS photo_storage_path text,
  ADD COLUMN IF NOT EXISTS nmls_number text,
  ADD COLUMN IF NOT EXISTS signature_title text,
  ADD COLUMN IF NOT EXISTS credentials_line text;

COMMENT ON COLUMN public.team.photo_storage_path IS 'Path in storage bucket email_signatures, e.g. photos/{team_id}.jpg. NULL if no photo uploaded yet.';
COMMENT ON COLUMN public.team.nmls_number IS 'NMLS mortgage licensing number. NULL for team members without one. When NULL, signature omits the NMLS# line entirely.';
COMMENT ON COLUMN public.team.signature_title IS 'Explicit title override for email signature. When NULL, generation falls back to role_level string.';
COMMENT ON COLUMN public.team.credentials_line IS 'Professional designations shown after name (e.g. "ChFC, CLU"). Do NOT prefix with space. NULL for team without designations.';

-- 2. Signature template table
CREATE TABLE IF NOT EXISTS public.email_signature_template (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  template_html text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  updated_by text,
  UNIQUE (agency_id)
);

ALTER TABLE public.email_signature_template ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "agency isolation" ON public.email_signature_template;
CREATE POLICY "agency isolation" ON public.email_signature_template
  FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- 4. Storage bucket for per-person photos
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'email_signatures',
  'email_signatures',
  false,
  5242880,
  ARRAY['image/jpeg', 'image/jpg', 'image/png']
)
ON CONFLICT (id) DO NOTHING;

-- 5. Storage RLS
DROP POLICY IF EXISTS "email_signatures agency read" ON storage.objects;
CREATE POLICY "email_signatures agency read" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'email_signatures');

DROP POLICY IF EXISTS "email_signatures agency write" ON storage.objects;
CREATE POLICY "email_signatures agency write" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'email_signatures');

DROP POLICY IF EXISTS "email_signatures agency update" ON storage.objects;
CREATE POLICY "email_signatures agency update" ON storage.objects
  FOR UPDATE TO authenticated
  USING (bucket_id = 'email_signatures')
  WITH CHECK (bucket_id = 'email_signatures');

DROP POLICY IF EXISTS "email_signatures agency delete" ON storage.objects;
CREATE POLICY "email_signatures agency delete" ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'email_signatures');
