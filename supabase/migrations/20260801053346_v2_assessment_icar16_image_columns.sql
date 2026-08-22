-- v2 assessment: extend hiregauge_instrument_items for ICAR-16 visual items (Matrix Reasoning + 3D Rotation)
-- Architecture locked 2026-07-31 late-pm session 3, OQ 23e20402. Schema extension approach —
-- item_image_url for the item stem image, choice_image_urls for image-based answer choices
-- (both Matrix Reasoning and 3D Rotation present answer options as images, not text).
-- Text-only items (Letter-Number Series, Verbal Reasoning) leave both columns NULL.
-- Images hosted in repo at public/icar/, served via Vercel CDN — not embedded as URLs in item_text.

ALTER TABLE public.hiregauge_instrument_items
  ADD COLUMN IF NOT EXISTS item_image_url TEXT,
  ADD COLUMN IF NOT EXISTS choice_image_urls JSONB;

COMMENT ON COLUMN public.hiregauge_instrument_items.item_image_url IS
  'URL to the item stem image, for visual items (e.g. ICAR-16 Matrix Reasoning grids, 3D Rotation cube shapes). NULL for text-only items.';
COMMENT ON COLUMN public.hiregauge_instrument_items.choice_image_urls IS
  'JSONB array of URLs to image-based answer choices, ordered to match answer_key indexing. NULL for text-only or free-text-choice items.';
