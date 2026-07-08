-- Tier 2: Scrub remaining BCC references in tasks (10 rows) and settings (2 rows)
-- Settings drive_bcc_* keys + /BCC/ path descriptions LEFT AS-IS pending Peter's decision
-- on renaming the actual Google Drive folder (currently still named "BCC").

-- Tasks: rename BCC → Newtworks in titles and descriptions
UPDATE public.tasks
SET title = REGEXP_REPLACE(title, '\yBCC\y', 'Newtworks', 'g'),
    description = REGEXP_REPLACE(COALESCE(description, ''), '\yBCC\y', 'Newtworks', 'g'),
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND (title ~ '\yBCC\y' OR COALESCE(description, '') ~ '\yBCC\y');

-- Settings: only touch descriptions that reference the APP name (not folder paths)
UPDATE public.settings
SET description = REGEXP_REPLACE(description, '\yBCC\y', 'Newtworks', 'g'),
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND setting_key IN ('groq_model_default', 'timezone')
  AND description ~ '\yBCC\y';
