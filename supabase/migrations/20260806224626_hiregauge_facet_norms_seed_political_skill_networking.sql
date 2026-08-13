-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-06 22:46:26 UTC (ledger name: hiregauge_facet_norms_seed_political_skill_networking) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260806224626.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
INSERT INTO hiregauge_facet_norms
  (agency_id, facet, ref_mean_0_100, ref_sd_0_100, source_scale, citation, retrieved_from, notes, updated_at, updated_by)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'political_skill_networking',
  65.00,
  17.33,
  'Political Skill Inventory, Networking Ability subscale, 6 items, 7-point Likert (1=strongly disagree..7=strongly agree) -- matches our item bank exactly',
  'Ferris, Treadway, Kolodinsky, Hochwarter, Kacmar, Douglas & Frink 2005, Journal of Management 31(1):126-152, Table 2 (Study 1, N=350)',
  'https://www.academia.edu/22716721/Development_and_Validation_of_the_Political_Skill_Inventory',
  'Combined-sample row read directly from Table 2, full primary-source text (R4: combined only -- no sex/age split reported for this subscale). Population: combined student (N=226, 50% female, southern US) + managerial/administrative university staff (N=124, ~70% female) samples, average age spans 22.6-39.5 across subsamples. Response format (7-point) matches our item bank exactly -- no scale-conversion caveat beyond the standard (x-1)/6 linear rescale to 0-100. Reliability alpha=.87. UPGRADE CANDIDATE: Study 2 Sample 2 in the same paper (Table 5, N=93, law-firm employees) reports M=5.00 SD=1.13 on the same subscale -- a smaller, more occupationally specific sample; not used here since Study 1 has the larger N and is the paper''s primary development sample.',
  NOW(),
  'claude_grunt_thread'
);

UPDATE alerts
SET is_resolved = true, resolved_at = NOW()
WHERE id = 'b60aa2fc-baa4-4781-bda0-3f1d73d68fa3'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';
