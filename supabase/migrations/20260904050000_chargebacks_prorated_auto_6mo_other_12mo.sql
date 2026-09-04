-- Chargebacks (Peter 2026-09-04): a canceled policy is matched to the sale that
-- wrote it (same customer + line, most recent active sale, same type preferred)
-- inside the window: 6 months auto, 12 months everything else. The Multiline
-- credit on that line comes back prorated to the part of the window left. Unpaid
-- credit is voided; paid credit gets a negative multiline_chargeback row in the
-- current week (source cancelation_log). Voiding the cancelation reverses it.
-- Referral Sold is a household credit and is not touched.
-- Live definition: migration chargebacks_prorated_auto_6mo_other_12mo in Supabase.
ALTER TABLE public.cancelation_log ADD COLUMN IF NOT EXISTS matched_sale_product_id uuid REFERENCES public.sales_log_products(id);
ALTER TABLE public.cancelation_log ADD COLUMN IF NOT EXISTS chargeback_activity_id uuid REFERENCES public.retention_activity_log(id);
ALTER TABLE public.cancelation_log ADD COLUMN IF NOT EXISTS chargeback_points numeric;
ALTER TABLE public.cancelation_log ADD COLUMN IF NOT EXISTS window_fraction_left numeric;
ALTER TABLE public.retention_activity_log DROP CONSTRAINT IF EXISTS retention_activity_log_source_check;
ALTER TABLE public.retention_activity_log ADD CONSTRAINT retention_activity_log_source_check
  CHECK (source = ANY (ARRAY['manual'::text, 'sales_log'::text, 'system'::text, 'cancelation_log'::text]));
