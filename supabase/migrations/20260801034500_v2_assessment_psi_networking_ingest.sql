-- v2 assessment: PSI Networking Ability subscale 6-item ingest into newtworks_v2_personality
-- Source: Ferris, G. R., Treadway, D. C., Kolodinsky, R. W., Hochwarter, W. A., Kacmar, C. J.,
--   Douglas, C., & Frink, D. D. (2005). Development and validation of the Political Skill Inventory.
--   Journal of Management, 31(1), 126-152.
-- Networking Ability subscale ONLY (6 items: positions 1, 6, 9, 10, 11, 15 of the 18-item PSI).
-- Not full PSI. Not Social Astuteness, Interpersonal Influence, or Apparent Sincerity subscales.
-- All 6 items +keyed (no reverse-coded items in PSI). 7-point Likert (1=strongly disagree, 7=strongly agree).
-- v2 item numbers 79-84, Stint 2, scale_max=7 (matches Seibert 1999 PPS scale_max).

INSERT INTO public.hiregauge_instrument_items (
  section, item_number, hypothesized_trait, item_text, reverse_coded, scale_max, stint, choices, notes
) VALUES
('newtworks_v2_personality', 79, 'political_skill_networking', 'I spend a lot of time and effort at work networking with others.',                                                                    false, 7, 2, NULL, 'PSI-NA item 1 of 6 (PSI position 1). Ferris et al. 2005 J. Management 31:126-152. Networking Ability subscale. 7-point scale, +keyed.'),
('newtworks_v2_personality', 80, 'political_skill_networking', 'I am good at building relationships with influential people at work.',                                                              false, 7, 2, NULL, 'PSI-NA item 2 of 6 (PSI position 6). Ferris et al. 2005 J. Management 31:126-152. Networking Ability subscale. 7-point scale, +keyed.'),
('newtworks_v2_personality', 81, 'political_skill_networking', 'I have developed a large network of colleagues and associates at work who I can call on for support when I really need to get things done.', false, 7, 2, NULL, 'PSI-NA item 3 of 6 (PSI position 9). Ferris et al. 2005 J. Management 31:126-152. Networking Ability subscale. 7-point scale, +keyed.'),
('newtworks_v2_personality', 82, 'political_skill_networking', 'At work, I know a lot of important people and am well connected.',                                                                  false, 7, 2, NULL, 'PSI-NA item 4 of 6 (PSI position 10). Ferris et al. 2005 J. Management 31:126-152. Networking Ability subscale. 7-point scale, +keyed.'),
('newtworks_v2_personality', 83, 'political_skill_networking', 'I spend a lot of time at work developing connections with others.',                                                                false, 7, 2, NULL, 'PSI-NA item 5 of 6 (PSI position 11). Ferris et al. 2005 J. Management 31:126-152. Networking Ability subscale. 7-point scale, +keyed.'),
('newtworks_v2_personality', 84, 'political_skill_networking', 'I am good at using my connections and network to make things happen at work.',                                                     false, 7, 2, NULL, 'PSI-NA item 6 of 6 (PSI position 15). Ferris et al. 2005 J. Management 31:126-152. Networking Ability subscale. 7-point scale, +keyed.');
