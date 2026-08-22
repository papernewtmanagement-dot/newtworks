UPDATE hiregauge_facet_norms
SET
  ref_mean_0_100 = 44.00,
  ref_sd_0_100 = 20.50,
  source_scale = 'O*NET Interest Profiler Short Form, Enterprising scale, 10 items, 5-point computerized administration (0=strongly dislike..4=strongly like) -- FORMAT-MATCHED to our item bank, supersedes prior 3-point paper-and-pencil figure',
  citation = 'Rounds, Wee, Cao, Song & Lewis 2016, "Development of an O*NET Mini Interest Profiler (Mini-IP) for Mobile Devices: Psychometric Characteristics," National Center for O*NET Development, Table 8 (60-Item Interest Profiler Short Form, Validation Sample N=575)',
  retrieved_from = 'https://www.onetcenter.org/dl_files/Mini-IP.pdf',
  notes = 'REPLACES prior row (seeded 2026-08-06 same day): 45.59/30.20, from Rounds, Su, Lewis & Rivkin 2010, Table 14 developmental sample -- that figure used the 3-point paper-and-pencil count-of-likes metric (0-10 range), a format mismatch against our 5-point item bank flagged in the original notes as an accepted-imprecision caveat. This report''s Table 8 supplies the FIRST format-matched official figure: same 10-item scale, same 5-point computerized administration our item bank uses. Official test manual, full text read directly. R4: combined only -- Total column used, not the Male/Female split. Population: Amazon MTurk validation sample, N=575 US adults, ages 18-65 (M=35.66, SD=11.38), 95.8% employed, 51.8% male, 77% White. AUDIT NOTE: the mean transferred across formats within 1.6 points (45.59 -> 44.00), but the count-format SD overstated the graded-format spread by ~47% (30.20 vs 20.50) -- count-format standard deviations do not transfer across response-format changes even when means roughly agree; this is the reason format-matching matters and future facet norms should prioritize matching administration format over matching source prestige when both are available.',
  updated_at = NOW(),
  updated_by = 'claude_grunt_thread'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND facet = 'enterprising';

UPDATE alerts
SET message = message || E'\n\n[2026-08-06 PARKED, planning thread ruling]: Two threads, three failed passes on Brown, Cron & Slocum 1998 (4-item WOFO-2 competitiveness subscale) -- instrument confirmed, no descriptive-stats table accessible anywhere. Ruling: PARKED until local-norms switchover (>=100 real completions). Single untried lead recorded for that future pass: Schrock 2016, Michigan State dissertation "Self-Oriented Competitiveness" (open access, d.lib.msu.edu/etd/4052), other-oriented trait competitiveness measured on salespeople, likely tables descriptives. Weight is 1 in only 2 of 7 roles -- low priority. Do not run further search passes on this facet unless explicitly redirected.'
WHERE id = '219740fe-6ccc-4cde-b9b0-39ed8cae8881'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';
