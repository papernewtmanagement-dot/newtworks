-- hiring-interview-scheduler v8 (commit e57b898) is live and reads candidate_id,
-- so the dispatch only ever touches the candidate who just finished. Safe to arm.
ALTER TABLE public.hiring_candidates ENABLE TRIGGER trg_dispatch_assessed_candidate;
