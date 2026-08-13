-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-06 22:47:21 UTC (ledger name: hiregauge_facet_norms_seed_customer_orientation) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260806224721.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
INSERT INTO hiregauge_facet_norms
  (agency_id, facet, ref_mean_0_100, ref_sd_0_100, source_scale, citation, retrieved_from, notes, updated_at, updated_by)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'customer_orientation',
  86.50,
  14.88,
  'SOCO short form (Thomas, Soutar & Ryan 2001), Customer Orientation subscale, 5 items, source 1-9 Likert scale -- use SOURCE scale range per Q1b ruling, not our 5-point administration',
  'Wachner, Plouffe & Gregoire 2009, Industrial Marketing Management 38:32-44, Table 1 (pooled sample N=398)',
  'https://chaireomerdesserres.hec.ca/wp-content/uploads/2019/06/WachnerPlouffegregoire.pdf',
  'Combined-sample row read directly from Table 1, full primary-source text (R4: combined only). Item text verified against Appendix A -- exact match to the 5-item TSR 2001 customer-orientation subscale in our item bank ("I try to figure out what the customer needs are," etc.), alpha=.91. Population: pooled US sample of 3 sub-samples -- 43 industrial cleaning-supplies salespeople (93% male), 117 residential real estate agents (37% male, older/more tenured), 238 mixed B2B/B2C convention attendees (53% male) -- heterogeneous occupational convenience sample, not a general population. Source-of-record for the ITEM TEXT stays Periatt/Thomas-Soutar-Ryan per the earlier Q1b ruling; this paper supplies only the descriptive numbers, both citations recorded per instruction. Periatt, LeMay & Chakrabarty 2004 confirmed DEAD END for descriptives (6-page cross-validation note, factor structure and correlations only, no scale means/SDs) -- do not re-attempt.',
  NOW(),
  'claude_grunt_thread'
);

UPDATE alerts
SET is_resolved = true, resolved_at = NOW()
WHERE id = '4f2a0563-6603-4001-b6c3-1a88d4e25e60'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';
