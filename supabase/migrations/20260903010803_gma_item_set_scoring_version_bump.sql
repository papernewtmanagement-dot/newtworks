-- Scoring-formula touch on _newtworks_role_fit_core: bump the version by hand
-- (op-rule "Scoring-formula changes to _newtworks_role_fit_core must manually
-- bump hiregauge_scoring_version"). On the current item set every input
-- resolves to exactly the same norm rows as before, so the recomputed
-- composites must come out identical to the pre-change snapshot -- that
-- equality is the regression check for this whole migration series.
UPDATE public.hiregauge_scoring_version
SET version = version + 1, updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';
