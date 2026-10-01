
-- Roleplaying mastery (Peter's ruling 2026-09-30, "any skill can become second nature"; page commit b72e9fa9 hides a
-- second-nature skill with the basics). The rule card says so; rpg_skill_tree already computes second_nature.
UPDATE public.rpg_rules SET body = body || $r$

A skill becomes second nature when every parent is second nature and its own number reaches its bar. A second-nature skill leaves the sheet's rows and shows with the basics, inside the skills built on it. It still rolls, still counts and still trains.
*Hope is built only from traits, so its bar is 3: Karen's Hope 7 is second nature from the start. Courage (bar 3) becomes second nature once Trust reaches 3 and Courage is 3 or more. Sword (bar 21) needs Courage, Endurance, Solo Battle, Swing arm, Grip and Footwork all second nature, and Sword itself at 21.*$r$,
 updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'skill_tree' AND body NOT LIKE '%becomes second nature when%';

