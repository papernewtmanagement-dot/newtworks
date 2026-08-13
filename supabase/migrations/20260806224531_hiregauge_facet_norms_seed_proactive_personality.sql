-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-06 22:45:31 UTC (ledger name: hiregauge_facet_norms_seed_proactive_personality) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260806224531.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
INSERT INTO hiregauge_facet_norms
  (agency_id, facet, ref_mean_0_100, ref_sd_0_100, source_scale, citation, retrieved_from, notes, updated_at, updated_by)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'proactive_personality',
  72.83,
  12.50,
  'Proactive Personality Scale (Seibert, Crant & Kraimer 1999), 10-item exact match, 7-point Likert (1=Strongly Disagree..7=Strongly Agree) -- matches our item bank and item text exactly',
  'Patterson, M.N. 2018, "Proactive Personality Benefits: The Role of Work-Life Salience, Career Encouragement, and Career Satisfaction," Master''s thesis, San Jose State University, SJSU ScholarWorks Master''s Theses No. 4916',
  'https://scholarworks.sjsu.edu/etd_theses/4916',
  'NOT PEER-REVIEWED -- single-employer technology-industry convenience sample, per ruling directive 3 fallback (one peer-reviewed pass run first this session against Thompson 2005 JAP and Joo & Ready 2012, neither surfaced a readable descriptive-stats table; falling back as authorized). N=1,338 analyzed (1,388 respondents), one IT employer, southern United States, 21% response rate, ages 23-70 (52% aged 40-50), 74.8% male, 77.5% White. Thesis explicitly states results not generalizable. Reliability alpha=.87, matches original Seibert/Crant/Kraimer .86. Reported M=5.37, SD=0.75 on 1-7 scale; converted via (x-1)/6*100. UPGRADE CANDIDATE: any peer-reviewed study administering this exact 10-item scale and reporting its own descriptive table, still unfound after two search passes across two sessions.',
  NOW(),
  'claude_grunt_thread'
);

UPDATE alerts
SET is_resolved = true, resolved_at = NOW()
WHERE id = '4644f697-eab4-4465-8047-78210fbd7735'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';
