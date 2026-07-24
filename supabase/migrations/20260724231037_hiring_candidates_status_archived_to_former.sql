-- Rename hiring_candidates.status value 'archived' → 'former' (semantic clarity: former team members)
-- and migrate 7 mis-labeled 'declined' rows for people who were actually hired pre-Newtworks.
-- Also create Andrew Weiser's placeholder row.

-- 1. Expand check constraint to allow both temporarily
ALTER TABLE public.hiring_candidates DROP CONSTRAINT IF EXISTS team_assessments_status_check;
ALTER TABLE public.hiring_candidates ADD CONSTRAINT team_assessments_status_check
  CHECK ((status IS NULL) OR (status = ANY (ARRAY[
    'applied'::text, 'assessed'::text, 'email_screen'::text, 'interview'::text,
    'reference_check'::text, 'offer'::text, 'hired'::text, 'declined'::text,
    'archived'::text, 'former'::text
  ])));

-- 2. Migrate Jason Fuller (currently 'archived') → 'former'
UPDATE public.hiring_candidates
SET status = 'former', updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND id = '22658ee8-6fd4-41bd-b4ad-73dfbbfbb7a4'  -- Jason Fuller
  AND status = 'archived';

-- 3. Migrate 7 mis-labeled 'declined' rows for pre-Newtworks former team members
UPDATE public.hiring_candidates
SET status = 'former', updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND status = 'declined'
  AND id IN (
    '2dde579c-1c0c-4341-8438-947515d5ca88',  -- Bob Williams
    'f327da83-e9b8-440a-848c-d21fbf624c4f',  -- Anthony Papini
    'dd425628-1ac5-48ef-80a2-7647ff6a5b2c',  -- Matthew Carlton
    '3cf5d615-310d-44f7-88ee-31c541b6bcda',  -- David Gebhardt
    '89e33a7a-152e-48c0-952c-f728806bf08f',  -- April Varian
    'f21abd25-fa0f-419d-b68b-60b18b4cd7a8',  -- Tara Birk
    '17652d2c-60ff-455b-83e9-a6369fecb496'   -- Cheryl Hemphill
  );

-- 4. Create Andrew Weiser placeholder row (former team, no data on file)
INSERT INTO public.hiring_candidates (agency_id, first_name, last_name, status, assessment_date, notes)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Andrew', 'Weiser', 'former', '2020-01-01',
  'Legacy former team member — pre-Newtworks. Assessment date is a sentinel; no assessment data on file.'
);

-- 5. Tighten constraint: drop 'archived' from allowed values (no rows left with it)
ALTER TABLE public.hiring_candidates DROP CONSTRAINT team_assessments_status_check;
ALTER TABLE public.hiring_candidates ADD CONSTRAINT team_assessments_status_check
  CHECK ((status IS NULL) OR (status = ANY (ARRAY[
    'applied'::text, 'assessed'::text, 'email_screen'::text, 'interview'::text,
    'reference_check'::text, 'offer'::text, 'hired'::text, 'declined'::text,
    'former'::text
  ])));
