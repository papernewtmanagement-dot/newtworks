-- Roleplaying world map step 14f4 cleanup (Peter 2026-10-08 17:55, decision 1A): the lakes sit in hollows since map44, so the
-- shares of land the old random lake field covered are no longer read.
DELETE FROM public.rpg_settings WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key IN ('map_lake_3_share', 'map_lake_4_share', 'map_lake_5_share');

