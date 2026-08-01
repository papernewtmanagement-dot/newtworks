-- v2 assessment: Proactive Personality Scale 10-item Seibert 1999 ingest into newtworks_v2_personality
-- Primary source: Seibert, S. E., Crant, J. M., & Kraimer, M. L. (1999). Proactive personality and career success.
--   Journal of Applied Psychology, 84(3), 416-427.
-- (NOTE: op-rule catalog currently cites Seibert/Kraimer/Crant 2001 — that paper USES this scale but does not publish it.
--  Correct primary source is 1999. Op-rule to be amended at session close.)
-- Original 17-item scale: Bateman, T. S., & Crant, J. M. (1993). J. Organizational Behavior 14:103-118.
-- Seibert 1999 selected 10 items with highest average factor loadings across 3 studies.
-- All 10 items +keyed (Seibert did not include Bateman & Crant's one reverse-coded item in the 10-item subset).
-- Item text verified verbatim from Patterson 2018 (SJSU MS thesis) Appendix — used Seibert 1999 scale in full.
-- 7-point Likert per source (1=Strongly Disagree ... 7=Strongly Agree). α=.86-.87 across studies.
-- v2 item numbers 69-78, Stint 2, scale_max=7 (third distinct scale in section: GSE 4-point, LOT-R/HEXACO/IPIP 5-point, this 7-point).

INSERT INTO public.hiregauge_instrument_items (
  section, item_number, hypothesized_trait, item_text, reverse_coded, scale_max, stint, choices, notes
) VALUES
('newtworks_v2_personality', 69, 'proactive_personality', 'I am constantly on the lookout for new ways to improve my life.',                       false, 7, 2, NULL, 'PPS Seibert 1999 item 1. Selected from Bateman & Crant 1993 17-item scale by highest avg factor loading. 7-point scale, +keyed.'),
('newtworks_v2_personality', 70, 'proactive_personality', 'Wherever I have been, I have been a powerful force for constructive change.',           false, 7, 2, NULL, 'PPS Seibert 1999 item 2. Selected from Bateman & Crant 1993 17-item scale by highest avg factor loading. 7-point scale, +keyed.'),
('newtworks_v2_personality', 71, 'proactive_personality', 'Nothing is more exciting than seeing my ideas turn into reality.',                      false, 7, 2, NULL, 'PPS Seibert 1999 item 3. Selected from Bateman & Crant 1993 17-item scale by highest avg factor loading. 7-point scale, +keyed.'),
('newtworks_v2_personality', 72, 'proactive_personality', 'If I see something I don''t like, I fix it.',                                            false, 7, 2, NULL, 'PPS Seibert 1999 item 4. Selected from Bateman & Crant 1993 17-item scale by highest avg factor loading. 7-point scale, +keyed.'),
('newtworks_v2_personality', 73, 'proactive_personality', 'No matter what the odds, if I believe in something I will make it happen.',             false, 7, 2, NULL, 'PPS Seibert 1999 item 5. Selected from Bateman & Crant 1993 17-item scale by highest avg factor loading. 7-point scale, +keyed.'),
('newtworks_v2_personality', 74, 'proactive_personality', 'I love being a champion for my ideas, even against others'' opposition.',              false, 7, 2, NULL, 'PPS Seibert 1999 item 6. Selected from Bateman & Crant 1993 17-item scale by highest avg factor loading. 7-point scale, +keyed.'),
('newtworks_v2_personality', 75, 'proactive_personality', 'I excel at identifying opportunities.',                                                  false, 7, 2, NULL, 'PPS Seibert 1999 item 7. Selected from Bateman & Crant 1993 17-item scale by highest avg factor loading. 7-point scale, +keyed.'),
('newtworks_v2_personality', 76, 'proactive_personality', 'I am always looking for better ways to do things.',                                     false, 7, 2, NULL, 'PPS Seibert 1999 item 8. Selected from Bateman & Crant 1993 17-item scale by highest avg factor loading. 7-point scale, +keyed.'),
('newtworks_v2_personality', 77, 'proactive_personality', 'If I believe in an idea, no obstacle will prevent me from making it happen.',           false, 7, 2, NULL, 'PPS Seibert 1999 item 9. Selected from Bateman & Crant 1993 17-item scale by highest avg factor loading. 7-point scale, +keyed.'),
('newtworks_v2_personality', 78, 'proactive_personality', 'I can spot a good opportunity long before others can.',                                  false, 7, 2, NULL, 'PPS Seibert 1999 item 10. Selected from Bateman & Crant 1993 17-item scale by highest avg factor loading. 7-point scale, +keyed.');
