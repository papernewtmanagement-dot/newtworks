-- v2 assessment: Enterprising (O*NET Interest Profiler Short Form) 10-item ingest into newtworks_v2_personality
-- Source: National Center for O*NET Development. O*NET Interest Profiler Short Form v1.
--   Public domain / CC BY 4.0, U.S. Dept. of Labor, Employment & Training Administration.
--   https://www.onetcenter.org/dl_tools/ipsf/Interest_Profiler.pdf (paper form, item text source).
-- CORRECTION: prior handoff said 8 items. Canonical Short Form Enterprising subscale is 10 items
--   (matches all 6 RIASEC subscales at 10 items each in the Short Form). Same error class as
--   HEXACO miscount in session 3 — verified against primary source before ingest.
-- FORMAT: paper form uses binary checkbox (would like to do / would not); computerized Short Form
--   uses a 5-point Strongly Dislike -> Strongly Like scale (O*NET Interest Profiler Manual v1.0,
--   psypack.com; matches most of this assessment's other Stint-2 items and keeps careless-response
--   / straight-line detection checks functional — checkbox format has no answer "position" to
--   detect repetition against). Item content unchanged from source; response format matches
--   O*NET's own computerized administration, not the print-only checkbox layout.
-- All 10 items +keyed (no reverse-coded items in this instrument).
-- v2 item numbers 109-118, Stint 2, scale_max=5 (0-4 scored per O*NET convention; stored as
--   1-5 on scale_max=5 to match this section's existing 1-N storage convention).

INSERT INTO public.hiregauge_instrument_items (
  section, item_number, hypothesized_trait, item_text, reverse_coded, scale_max, stint, choices, notes
) VALUES
('newtworks_v2_personality', 109, 'enterprising', 'Buy and sell stocks and bonds',            false, 5, 2, NULL, 'O*NET IPSF Enterprising item 1 of 10. National Center for O*NET Development, public domain/CC BY 4.0. Content from paper Short Form; response scale matches O*NET computerized 5-pt format. +keyed.'),
('newtworks_v2_personality', 110, 'enterprising', 'Negotiate business contracts',             false, 5, 2, NULL, 'O*NET IPSF Enterprising item 2 of 10. National Center for O*NET Development, public domain/CC BY 4.0. Content from paper Short Form; response scale matches O*NET computerized 5-pt format. +keyed.'),
('newtworks_v2_personality', 111, 'enterprising', 'Manage a retail store',                    false, 5, 2, NULL, 'O*NET IPSF Enterprising item 3 of 10. National Center for O*NET Development, public domain/CC BY 4.0. Content from paper Short Form; response scale matches O*NET computerized 5-pt format. +keyed.'),
('newtworks_v2_personality', 112, 'enterprising', 'Represent a client in a lawsuit',          false, 5, 2, NULL, 'O*NET IPSF Enterprising item 4 of 10. National Center for O*NET Development, public domain/CC BY 4.0. Content from paper Short Form; response scale matches O*NET computerized 5-pt format. +keyed.'),
('newtworks_v2_personality', 113, 'enterprising', 'Operate a beauty salon or barber shop',    false, 5, 2, NULL, 'O*NET IPSF Enterprising item 5 of 10. National Center for O*NET Development, public domain/CC BY 4.0. Content from paper Short Form; response scale matches O*NET computerized 5-pt format. +keyed.'),
('newtworks_v2_personality', 114, 'enterprising', 'Market a new line of clothing',            false, 5, 2, NULL, 'O*NET IPSF Enterprising item 6 of 10. National Center for O*NET Development, public domain/CC BY 4.0. Content from paper Short Form; response scale matches O*NET computerized 5-pt format. +keyed.'),
('newtworks_v2_personality', 115, 'enterprising', 'Manage a department within a large company', false, 5, 2, NULL, 'O*NET IPSF Enterprising item 7 of 10. National Center for O*NET Development, public domain/CC BY 4.0. Content from paper Short Form; response scale matches O*NET computerized 5-pt format. +keyed.'),
('newtworks_v2_personality', 116, 'enterprising', 'Sell merchandise at a department store',   false, 5, 2, NULL, 'O*NET IPSF Enterprising item 8 of 10. National Center for O*NET Development, public domain/CC BY 4.0. Content from paper Short Form; response scale matches O*NET computerized 5-pt format. +keyed.'),
('newtworks_v2_personality', 117, 'enterprising', 'Start your own business',                  false, 5, 2, NULL, 'O*NET IPSF Enterprising item 9 of 10. National Center for O*NET Development, public domain/CC BY 4.0. Content from paper Short Form; response scale matches O*NET computerized 5-pt format. +keyed.'),
('newtworks_v2_personality', 118, 'enterprising', 'Manage a clothing store',                  false, 5, 2, NULL, 'O*NET IPSF Enterprising item 10 of 10. National Center for O*NET Development, public domain/CC BY 4.0. Content from paper Short Form; response scale matches O*NET computerized 5-pt format. +keyed.');
