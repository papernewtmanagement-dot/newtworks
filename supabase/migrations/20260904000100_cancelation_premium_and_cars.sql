-- Canceled policies carry the premium that walked and, on auto, the car
-- count, the same as sold policies. The premium is what the chargeback
-- step will match on later. Function bodies are the live definitions;
-- see migration 20260904 cancelation_premium_and_cars in Supabase.
ALTER TABLE public.cancelation_log ADD COLUMN IF NOT EXISTS premium numeric;
ALTER TABLE public.cancelation_log ADD COLUMN IF NOT EXISTS vehicle_count integer;
ALTER TABLE public.cancelation_log DROP CONSTRAINT IF EXISTS cancelation_log_premium_check;
ALTER TABLE public.cancelation_log ADD CONSTRAINT cancelation_log_premium_check CHECK (premium IS NULL OR premium >= 0);
-- rp_log_cancelation: reads premium + vehicle_count from the payload, validates, stores them.
-- rp_log_entry: passes premium + vehicle_count per canceled item through.
