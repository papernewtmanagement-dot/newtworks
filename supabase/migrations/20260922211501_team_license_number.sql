-- The person's insurance license number, one per person. Typed on the Team card.
ALTER TABLE public.team ADD COLUMN IF NOT EXISTS license_number text;
