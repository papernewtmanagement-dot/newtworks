-- Fix orphaned depth-0 placement: the 4 pages added 2026-07-15 from Confluence
-- (Save Household, Save Life, Review Policy, Review New Young Driver) were
-- inserted with parent_page_id='2717679617', a Confluence grouping page that
-- was never migrated into public.manuals. Tree builder can't resolve the
-- parent → rows fall through to depth 0, appearing as siblings of the
-- icon-bearing sections in the Processes sidebar.
--
-- Correct parent: 1747025922 (Retention Appointments 📅) — the actual
-- Newtworks section they belong under. Migration comment on the original
-- insert explicitly named them as children of Retention Appointments.
UPDATE public.manuals
SET parent_page_id = '1747025922',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND manual_type = 'processes'
  AND is_active = true
  AND parent_page_id = '2717679617'
  AND confluence_page_id IN ('929464910', '1459060740', '982581320', '1478033409');
