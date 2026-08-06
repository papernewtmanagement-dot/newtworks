ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS is_test_candidate boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.hiring_candidates.is_test_candidate IS 'Internal smoke-test rows (owner/family walkthroughs). TRUE = excluded from calibration sample counts (N=15 / 25-30 / 30 reviews), invite stop-gates, and instrument-freeze semantics. A real completion means is_test_candidate = false.';
