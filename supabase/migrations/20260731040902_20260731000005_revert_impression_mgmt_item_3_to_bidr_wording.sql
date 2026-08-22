-- Revert item 3 to the BIDR-validated wording per hiregauge_trait_documentation.
-- Rewording in migration 20260731000004 was applied without reading the construct
-- documentation, which explicitly cites "Have sometimes had to tell a lie" as the
-- source BIDR item. Rewording departed from documented construct. Restoring.
-- Peter and Alvi's stored responses were originally against this wording, so no
-- rescoring needed — reverting brings the item back into alignment with the
-- responses on file.
UPDATE public.hiregauge_instrument_items
SET item_text = 'Have sometimes had to tell a lie.',
    notes = COALESCE(notes || E'\n', '') || '2026-07-30: reverted rewording per BIDR construct alignment. See hiregauge_trait_documentation.impression_management.construct_notes which cites this exact wording. Peter''s original parsing concern ("had to" reads as compulsion in analytical respondents) is a known BIDR item quirk that is generally acceptable given the validated psychometric behavior.',
    updated_at = NOW()
WHERE id = '62cbd9af-24b5-490d-80e0-d82ab5016b56'
  AND item_text = 'Have sometimes told a lie.';
