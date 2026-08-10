-- A backup of extracted page content must outlive the page it came from.
-- The FK to manuals(id) made the backup un-keepable once the source page was deleted,
-- which is exactly when the backup matters most. Drop the FK, keep the column as a soft reference.
ALTER TABLE public.manuals_faq_extraction_backup
  DROP CONSTRAINT IF EXISTS manuals_faq_extraction_backup_manual_id_fkey;

ALTER TABLE public.manuals_faq_extraction_backup
  ADD COLUMN IF NOT EXISTS manual_title text;

COMMENT ON COLUMN public.manuals_faq_extraction_backup.manual_id IS
  'Soft reference to the originating manuals.id. Intentionally NOT a foreign key — the source page is usually deleted after extraction.';
