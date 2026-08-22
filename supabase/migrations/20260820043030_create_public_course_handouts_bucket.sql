-- Public storage bucket for financial literacy course handouts.
-- WHY: the app is behind Vercel Authentication (ssoProtection = all_except_custom_domains),
-- so a PDF served from newtworks.vercel.app returns 401 to anyone without a Vercel
-- session — which is exactly the State Farm computer case the handouts exist for.
-- Supabase storage public URLs need no login and sit on the same host the app already
-- calls, so they are reachable anywhere the app itself works.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('course-handouts', 'course-handouts', true, 26214400, ARRAY['application/pdf'])
ON CONFLICT (id) DO UPDATE SET public = true;

-- Read is open by design (public bucket). Writes stay closed to anon/authenticated:
-- uploads happen with the service role key only.
DROP POLICY IF EXISTS "course_handouts_public_read" ON storage.objects;
CREATE POLICY "course_handouts_public_read" ON storage.objects
  FOR SELECT USING (bucket_id = 'course-handouts');
