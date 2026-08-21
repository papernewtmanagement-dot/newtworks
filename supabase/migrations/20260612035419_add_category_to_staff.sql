-- Add category column to split agency staff (producers, AMs, support tied to book) from admin staff
ALTER TABLE public.staff
  ADD COLUMN IF NOT EXISTS category text NOT NULL DEFAULT 'agency';

-- Enforce allowed values
ALTER TABLE public.staff
  DROP CONSTRAINT IF EXISTS staff_category_check;
ALTER TABLE public.staff
  ADD CONSTRAINT staff_category_check CHECK (category IN ('agency','admin'));

-- Index for fast filtering
CREATE INDEX IF NOT EXISTS staff_category_idx ON public.staff (category);

-- Move Leslie Jones to admin
UPDATE public.staff
SET category = 'admin', updated_at = NOW()
WHERE id = '6c9e8570-7e2d-41c9-b19d-60379b158d13';
