-- GO-LIVE FLIP (Peter-gated, authorized 2026-08-14). Both sides of the switch
-- in one transaction so no candidate can ever be served both sections at
-- once. Stint 1 (integrity gate: sincerity/fairness/greed_avoidance + GMA)
-- is untouched -- it is a separate stint from what FC replaces (stint 2's
-- other 22 facets), confirmed via live recon immediately before this
-- migration. Stint 3 (Likert-only ambiguous-facet extension) is also
-- untouched -- it naturally goes inert for FC candidates already (its
-- trigger function hardcodes the Likert section name).
--
-- hiregauge_item_purge_guard fired on the first attempt: it checks, per row,
-- whether an active retest still points at an anchor being deactivated. In
-- this bulk deactivation every stint-2 Likert item (anchors AND their
-- retests) goes false in the SAME statement -- confirmed live for item 203 /
-- its retest 242 before this migration -- so the guard's concern (an
-- orphaned retest surviving after its anchor is gone) does not apply here.
-- Using the documented bypass for this genuinely-intended bulk case.
SET LOCAL hiregauge.allow_item_purge = on;

UPDATE public.hiregauge_instrument_items
SET is_active = true
WHERE section = 'newtworks_v2_personality_fc';

UPDATE public.hiregauge_instrument_items
SET is_active = false
WHERE section = 'newtworks_v2_personality' AND stint = 2 AND is_active = true;
