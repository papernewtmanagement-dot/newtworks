UPDATE public.hiring_candidates SET reliability = 'high' WHERE reliability = 'very_high';

ALTER TABLE public.hiring_candidates DROP CONSTRAINT IF EXISTS staff_assessments_reliability_check;
ALTER TABLE public.hiring_candidates ADD CONSTRAINT hiring_candidates_reliability_check CHECK (reliability IS NULL OR reliability IN ('low','moderate','high'));

ALTER TABLE public.hiring_candidates DROP CONSTRAINT IF EXISTS staff_assessments_response_distortion_check;
ALTER TABLE public.hiring_candidates ADD CONSTRAINT hiring_candidates_response_distortion_check CHECK (response_distortion IS NULL OR response_distortion IN ('low','moderate','high'));
