-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-29 18:16:46 UTC (ledger name: rename_bcc_to_newtworks_in_automation_recipes) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260729181646.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Coordinate with Gmail label rename BCC/* → Newtworks/*
-- and Drive folder rename BCC-Bank-*/BCC-CC-* → Bank-*/CC-* (redundant prefix dropped, already inside Newtworks/2026/)

-- Bank Alert Ingestor: gmail_labels + drive_folders + universal_archive_label_names + subject
UPDATE public.automation_recipes
SET input_config = REPLACE(REPLACE(input_config::text, '"BCC/', '"Newtworks/'), '"BCC-', '"')::jsonb,
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Bank Alert Ingestor';

-- Time Off Vote Ingestor: universal_archive_label_names
UPDATE public.automation_recipes
SET input_config = REPLACE(input_config::text, '"BCC/', '"Newtworks/')::jsonb,
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Time Off Vote — Email Reply Ingestor';

-- Weekly Cash Pulse: cosmetic subject_template
UPDATE public.automation_recipes
SET input_config = REPLACE(input_config::text, 'BCC Weekly', 'Newtworks Weekly')::jsonb,
    output_config = REPLACE(output_config::text, 'BCC Weekly', 'Newtworks Weekly')::jsonb,
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Weekly Cash Pulse';
