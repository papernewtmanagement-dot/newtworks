-- keep the marketing source exactly as it read on the source record
ALTER TABLE public.sales_log ADD COLUMN IF NOT EXISTS marketing_source_import text;
COMMENT ON COLUMN public.sales_log.marketing_source_import IS 'Marketing source exactly as it read on the imported record, before it was mapped to a source key.';
ALTER TABLE public.quote_log ADD COLUMN IF NOT EXISTS marketing_source_import text;

INSERT INTO public.sales_marketing_sources (agency_id, source_key, label, sort_order, is_active) VALUES
  ('126794dd-25ff-47d2-a436-724499733365','statefarm_com','StateFarm.com',30,true),
  ('126794dd-25ff-47d2-a436-724499733365','everquote','EverQuote',40,true),
  ('126794dd-25ff-47d2-a436-724499733365','quotewizard','QuoteWizard',50,true),
  ('126794dd-25ff-47d2-a436-724499733365','corporate_marketing','Corporate Marketing',60,true),
  ('126794dd-25ff-47d2-a436-724499733365','state_to_state','State-to-State Transfer',70,true)
ON CONFLICT DO NOTHING;

-- the generic buckets these replace
DELETE FROM public.sales_marketing_sources
 WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND source_key IN ('internet_lead','sf_lead');

UPDATE public.sales_marketing_sources SET sort_order = 80  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND source_key='walk_in';
UPDATE public.sales_marketing_sources SET sort_order = 90  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND source_key='call_in';
UPDATE public.sales_marketing_sources SET sort_order = 100 WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND source_key='website';
UPDATE public.sales_marketing_sources SET sort_order = 110 WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND source_key='social_media';
UPDATE public.sales_marketing_sources SET sort_order = 120 WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND source_key='community_event';
UPDATE public.sales_marketing_sources SET sort_order = 130 WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND source_key='mailer';
