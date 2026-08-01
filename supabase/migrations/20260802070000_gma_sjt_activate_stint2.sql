-- Flip GMA (75 items) and SJT (40 items) from the stint=0/is_active=false
-- inert placeholder to stint=2/is_active=true -- joins the existing v2
-- fixed core battery alongside personality. Companion edge-function change
-- (commit b9fbd3d) adds both sections to V2_SECTIONS so v1-assessment
-- actually serves/saves them. Facet scoring
-- (compute_newtworks_v2_facets_as_row) is hardcoded to
-- section='newtworks_v2_personality' and safely ignores these -- GMA/SJT
-- responses are served, saved, and scored correct/incorrect via answer_key,
-- but no rollup function reads them yet.
UPDATE hiregauge_instrument_items
SET stint = 2, is_active = true, updated_at = now()
WHERE section IN ('newtworks_v2_cognitive_gma', 'newtworks_v2_sjt');
