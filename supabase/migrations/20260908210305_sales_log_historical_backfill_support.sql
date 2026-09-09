-- 1. issued date (sale_date stays = submitted date)
ALTER TABLE public.sales_log ADD COLUMN IF NOT EXISTS issued_date date;
COMMENT ON COLUMN public.sales_log.sale_date IS 'Date the business was submitted.';
COMMENT ON COLUMN public.sales_log.issued_date IS 'Date the policy issued. NULL = not issued yet.';

-- 2. mark rows that came from a historical load rather than a live entry
ALTER TABLE public.sales_log ADD COLUMN IF NOT EXISTS entry_source text NOT NULL DEFAULT 'manual';
DO $$ BEGIN
  ALTER TABLE public.sales_log ADD CONSTRAINT sales_log_entry_source_check
    CHECK (entry_source = ANY (ARRAY['manual'::text,'historical_backfill'::text]));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 3. verbatim State Farm eCRM marketing source text, kept alongside the mapped key
ALTER TABLE public.sales_log ADD COLUMN IF NOT EXISTS marketing_source_raw text;
COMMENT ON COLUMN public.sales_log.marketing_source_raw IS 'Marketing source exactly as it read on the source record. Kept so the mapped key is never the only copy.';

-- 4. historical rows have no ECRM link, no GNC answer, and sometimes no source.
--    Relax the blanket NOT NULLs, then require them only for live manual entries.
ALTER TABLE public.sales_log ALTER COLUMN ecrm_opportunity_url DROP NOT NULL;
ALTER TABLE public.sales_log ALTER COLUMN gnc_used DROP NOT NULL;
ALTER TABLE public.sales_log ALTER COLUMN marketing_source DROP NOT NULL;
DO $$ BEGIN
  ALTER TABLE public.sales_log ADD CONSTRAINT sales_log_manual_entry_required_fields
    CHECK (
      entry_source <> 'manual'
      OR (ecrm_opportunity_url IS NOT NULL AND gnc_used IS NOT NULL AND marketing_source IS NOT NULL)
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
