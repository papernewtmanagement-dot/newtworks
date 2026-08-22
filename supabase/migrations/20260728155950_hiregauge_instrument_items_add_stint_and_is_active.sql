-- Newtworks v1 Stint 2 build, step 1 of 10 per handoff 2026-07-28.
-- Adds adaptive-instrument columns to hiregauge_instrument_items.
--   stint      : which sitting-block an item belongs to
--                (1 = every candidate, 2 = expansion triggered by scores).
--                Nullable during backfill; step 3 populates for
--                newtworks_v1_personality section.
--   is_active  : soft-disable flag for retiring items without deletion.
--                Defaults true so all 240 existing rows stay live.
ALTER TABLE public.hiregauge_instrument_items
  ADD COLUMN IF NOT EXISTS stint     integer;

ALTER TABLE public.hiregauge_instrument_items
  ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;

-- Helpful for the stint-filtered reads that compute_newtworks_v1_traits
-- will start doing in step 9.
CREATE INDEX IF NOT EXISTS idx_hiregauge_instrument_items_section_stint_active
  ON public.hiregauge_instrument_items (section, stint, is_active);
