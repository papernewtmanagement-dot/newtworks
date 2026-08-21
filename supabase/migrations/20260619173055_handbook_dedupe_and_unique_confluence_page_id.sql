
-- Dedupe handbook table: keep newest row per confluence_page_id (by updated_at, then created_at)
-- Then enforce uniqueness going forward via partial unique index.

WITH ranked AS (
  SELECT 
    id,
    ROW_NUMBER() OVER (
      PARTITION BY confluence_page_id 
      ORDER BY updated_at DESC, created_at DESC
    ) AS rn
  FROM public.handbook
  WHERE confluence_page_id IS NOT NULL
)
DELETE FROM public.handbook
WHERE id IN (SELECT id FROM ranked WHERE rn > 1);

-- Add partial unique index (allows multiple NULLs for any BCC-native pages)
CREATE UNIQUE INDEX IF NOT EXISTS handbook_confluence_page_id_unique
  ON public.handbook (confluence_page_id)
  WHERE confluence_page_id IS NOT NULL;

