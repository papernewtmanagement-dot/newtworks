-- Peter directive 2026-08-05: all trait items move to the 5-point agreement
-- scale. Supersedes the 2026-08-01 "mixed scale sizes are locked" decision —
-- Peter's preference was always 5-for-consistency; the mixed sizes were held
-- on source-format-fidelity grounds that turn out to be moot because
-- compute_newtworks_v2_facets_as_row already normalizes every response to a
-- 0-100 position via (value-1)/(scale_max-1) per item. Verified before this
-- migration: every scoring/detection function either reads scale_max per item
-- (facets, stint-3 triggers, even-odd consistency, retest divergence,
-- impression management, stint-1 exit gate) or is scale-independent (GMA, SJT,
-- timing, bogus-vocab); raw straight-lining actually becomes MORE correct on
-- a uniform scale. Zero real-candidate responses exist on non-5 items (only
-- the Selftest row), so there is no comparability split — this is the
-- pre-data window.
DO $$
DECLARE
  v_foreign int;
  v_active_non5 int;
  v_items int;
  v_wiped int;
BEGIN
  -- Hard safety: abort if any real candidate has responses on non-5 items.
  SELECT count(*) INTO v_foreign
  FROM hiregauge_candidate_responses r
  JOIN hiregauge_instrument_items i ON i.id = r.item_id
  JOIN hiring_candidates hc ON hc.id = r.candidate_id
  WHERE i.section = 'newtworks_v2_personality'
    AND i.scale_max IS NOT NULL AND i.scale_max <> 5
    AND hc.candidate_name <> 'Selftest Newtworks';
  IF v_foreign > 0 THEN
    RAISE EXCEPTION 'aborting: % real-candidate responses exist on non-5-point items', v_foreign;
  END IF;

  SELECT count(*) INTO v_active_non5
  FROM hiregauge_instrument_items
  WHERE section = 'newtworks_v2_personality' AND is_active
    AND scale_max IS NOT NULL AND scale_max <> 5;
  IF v_active_non5 <> 63 THEN
    RAISE EXCEPTION 'expected 63 active non-5 items, found %', v_active_non5;
  END IF;

  -- Wipe Selftest responses recorded on the old 1-4 / 1-6 / 1-7 ranges;
  -- a stored 7 against a 5-point item would normalize past 100.
  DELETE FROM hiregauge_candidate_responses r
  USING hiregauge_instrument_items i, hiring_candidates hc
  WHERE i.id = r.item_id AND hc.id = r.candidate_id
    AND i.section = 'newtworks_v2_personality'
    AND i.scale_max IS NOT NULL AND i.scale_max <> 5
    AND hc.candidate_name = 'Selftest Newtworks';
  GET DIAGNOSTICS v_wiped = ROW_COUNT;

  -- Convert active AND inactive rows so the bank stays uniform if anything
  -- is ever reactivated.
  UPDATE hiregauge_instrument_items
  SET scale_max = 5,
      notes = COALESCE(notes || E'\n', '') || '2026-08-05: scale_max standardized to 5 per Peter — every trait item now shares the 5-point agreement scale. Facet scoring normalizes per item, so no scoring change needed.',
      updated_at = NOW()
  WHERE section = 'newtworks_v2_personality'
    AND scale_max IS NOT NULL AND scale_max <> 5;
  GET DIAGNOSTICS v_items = ROW_COUNT;

  RAISE NOTICE 'converted % items (63 active), wiped % Selftest responses', v_items, v_wiped;
END $$;
