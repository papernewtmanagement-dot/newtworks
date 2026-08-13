-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-06 22:43:28 UTC (ledger name: hiregauge_facet_norms_seed_dispositional_optimism) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260806224328.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
INSERT INTO hiregauge_facet_norms
  (agency_id, facet, ref_mean_0_100, ref_sd_0_100, source_scale, citation, retrieved_from, notes, updated_at, updated_by)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'dispositional_optimism',
  71.67,
  12.92,
  'LOT-R (Life Orientation Test-Revised), 6 scored items, 5-point 0-4 admin, total 0-24 -- matches our item bank exactly',
  'Schou-Bredal, Heir, Skogstad, Bonsaksen, Lerdal, Grimholt & Ekeberg 2017, International Journal of Clinical and Health Psychology 17(3):216-224, Table 2 (Total sample, All age groups, N=1,773)',
  'https://www.elsevier.es/en-revista-international-journal-clinical-health-psychology-355-articulo-population-based-norms-life-orientation-testrevised-S1697260017300522',
  'Combined-sample row read directly from Table 2, open-access full text (R4: combined only). Population: representative Norwegian general-population sample, ages 18-94, N=1,792 (1,773 with valid LOT-R). Response format (5-point, 0-4, 6 scored items) matches our administration exactly -- no scale-conversion caveat. UPGRADE CANDIDATE: Glaesmer, Rief, Martin, Mewes, Brahler, Zenger & Hinz 2012, British Journal of Health Psychology 17(2):432-445 (German general population, N=2,372, M=15.2) -- this paper''s own discussion section independently confirms that German figure by name, cross-validating the tertiary-page numbers already in circulation, but its own Table 5 was not directly readable this session (Wiley bot-detection). Herzberg, Glaesmer & Hoyer 2006 Psychological Assessment 18(4):433-438 also unreached. Swap in a direct read of either via single-row UPDATE if obtained.',
  NOW(),
  'claude_grunt_thread'
);

UPDATE alerts
SET is_resolved = true, resolved_at = NOW()
WHERE id = '4ce0e526-eb5d-44e1-adfa-ef2438441910'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';
