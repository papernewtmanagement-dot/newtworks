-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-06 22:45:03 UTC (ledger name: hiregauge_facet_norms_seed_enterprising) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260806224503.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
INSERT INTO hiregauge_facet_norms
  (agency_id, facet, ref_mean_0_100, ref_sd_0_100, source_scale, citation, retrieved_from, notes, updated_at, updated_by)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'enterprising',
  45.59,
  30.20,
  'O*NET Interest Profiler Short Form, Enterprising scale, 10 items -- SOURCE METRIC IS 3-point paper-and-pencil count-of-likes (0-10 range), NOT the 5-point computerized sum (0-40) our item bank uses. Rescaled 0-10 -> 0-100.',
  'Rounds, Su, Lewis & Rivkin 2010, O*NET Interest Profiler Short Form Psychometric Characteristics: Summary, National Center for O*NET Development (official U.S. Dept of Labor technical report), Table 14, developmental sample N=1061',
  'https://www.onetcenter.org/dl_files/IPSF_Psychometric.pdf',
  'Official test manual, full text read directly (not a citing paper). R4: combined only -- Table 14 reports Enterprising only by gender (Male n=437 M=4.43 SD=2.96; Female n=624 M=4.65 SD=3.06), no combined figure printed. Combined figure computed here via standard weighted-mean + pooled-variance formula from the two reported subgroups (shown: pooled mean=4.559, pooled SD=3.020 on the 0-10 scale) -- derived arithmetic from directly-read primary statistics, not an invented number. RESPONSE-FORMAT CAVEAT (per alert 2ddbdf5a): this report''s own Enterprising statistics are from the 3-point paper-and-pencil administration (like/dislike/unsure, summed as count of "likes" out of 10 items, range 0-10). Our item bank uses the 5-point computerized format (0-4 per item, summed, range 0-40) per the same report''s own description of the computerized Short Form. No separate computerized-format descriptive table was found in this report or any other O*NET Center publication after this search pass -- the Center appears to have only ever published norms on the paper-and-pencil metric. Rescaled 0-10 to 0-100 as a percentage-of-max, consistent with how every other facet in this table converts item-level maxima to 0-100; this does not assume item-level equivalence between the two response formats, only that both express degree of endorsement of the same 10 Enterprising activities. Accepted imprecision per spec 2.iii given no computerized-format alternative exists to check against. Candidate figure from the alert (M=4.20, SD=2.70) was NOT used -- it did not match this table and its exact source/table could not be confirmed this session.',
  NOW(),
  'claude_grunt_thread'
);

UPDATE alerts
SET is_resolved = true, resolved_at = NOW()
WHERE id = '2ddbdf5a-8d88-4975-9905-882ccab97699'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';
