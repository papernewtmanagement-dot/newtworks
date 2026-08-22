-- Safety hold (2026-08-21). The trigger dispatches with candidate_id, but the
-- deployed hiring-interview-scheduler bundle does not read candidate_id yet —
-- it would fall back to sweeping every eligible candidate in 'assessed',
-- including the 17 Peter asked to hold. Disabled until the new bundle
-- (commit e57b898) is deployed; re-enable with:
--   ALTER TABLE public.hiring_candidates ENABLE TRIGGER trg_dispatch_assessed_candidate;
ALTER TABLE public.hiring_candidates DISABLE TRIGGER trg_dispatch_assessed_candidate;
