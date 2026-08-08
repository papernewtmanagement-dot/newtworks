-- Batch 0 / 0B — norm provenance flag
-- Records that a facet's item wordings were neutralized after its published
-- norm was captured, so the facet's percentile-vs-norm reads shifted low in
-- absolute terms (while still ordering candidates correctly). Not set true
-- for anything by this migration -- each future item-rewording batch sets
-- it true for the facets that batch touches, as its own final step.

ALTER TABLE public.hiregauge_facet_norms
  ADD COLUMN IF NOT EXISTS items_reworded_after_norm boolean NOT NULL DEFAULT false;
