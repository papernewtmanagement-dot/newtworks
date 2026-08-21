ALTER TABLE public.agency
  ADD COLUMN IF NOT EXISTS on_time_smvc_current numeric DEFAULT 0.0217;

UPDATE public.agency
SET on_time_smvc_current = COALESCE(on_time_smvc_current, 0.0217)
WHERE id = '126794dd-25ff-47d2-a436-724499733365';
