-- Roleplaying unification, creature cards become full templates (2026-09-26).
-- Cardinal rule: characters, creatures and objects use one rulebook. A creature is made from its card the way a
-- character is made from Human: its traits roll with the card's dividers (or take set numbers, a boss), then the card's
-- experience is spent up the one level ladder. Every number after that comes from the same sheet math as a character's.
-- 1. Each card's own skills, the ones its actions roll, built from traits like any skill (divisor = sum of weights).
-- 2. Each action names the skill it rolls (skill_key). The printed number (skill) stays until fights make creatures from
--    their cards; it matches a typical creature from the card.
-- 3. Blueprints: Bramblemaw is a boss (every trait set); the other four roll with dividers and carry experience.
--    Beasts are on the good side like a Human (their evil sides are 0); the Bramblemaw and the Gloam Wisp are evil
--    (their good sides are 0).
-- 4. The GM card shows which skill an action rolls; the Rules tab says which card a card-only skill belongs to and
--    keeps a hidden card's skills off the players' page. The rule card "Creature Cards at the Table" is rewritten.

-- 1. Card skills.
INSERT INTO public.rpg_stat_definitions (agency_id, key, name, grp, kind, trainable, formula, sort_order, template_key)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'claw',            'Claw',            'fighting', 'derived', true, '{"div": 4, "parts": [["CO", 1], ["ST", 2], ["AG", 1]]}', 800, 'bramblemaw'),
  ('126794dd-25ff-47d2-a436-724499733365', 'bite',            'Bite',            'fighting', 'derived', true, '{"div": 4, "parts": [["CO", 1], ["ST", 2], ["PR", 1]]}', 805, 'bramblemaw'),
  ('126794dd-25ff-47d2-a436-724499733365', 'rending_swipe',   'Rending Swipe',   'fighting', 'derived', true, '{"div": 2, "parts": [["claw", 1], ["AG", 1]]}', 810, 'bramblemaw'),
  ('126794dd-25ff-47d2-a436-724499733365', 'briar_roar',      'Briar Roar',      'fighting', 'derived', true, '{"div": 4, "parts": [["CO", 2], ["ST", 1], ["FO", 1]]}', 815, 'bramblemaw'),
  ('126794dd-25ff-47d2-a436-724499733365', 'grasping_roots',  'Grasping Roots',  'fighting', 'derived', true, '{"div": 4, "parts": [["CG", 1], ["FO", 2], ["PR", 1]]}', 820, 'bramblemaw'),
  ('126794dd-25ff-47d2-a436-724499733365', 'talon_dive',      'Talon Dive',      'fighting', 'derived', true, '{"div": 4, "parts": [["CO", 1], ["ST", 2], ["AG", 1]]}', 830, 'ashwing_harrier'),
  ('126794dd-25ff-47d2-a436-724499733365', 'hunting_screech', 'Hunting Screech', 'fighting', 'derived', true, '{"div": 4, "parts": [["CO", 2], ["EN", 1], ["FO", 1]]}', 835, 'ashwing_harrier'),
  ('126794dd-25ff-47d2-a436-724499733365', 'shell_slam',      'Shell Slam',      'fighting', 'derived', true, '{"div": 4, "parts": [["CO", 1], ["ST", 1], ["AG", 2]]}', 840, 'mossback_elder'),
  ('126794dd-25ff-47d2-a436-724499733365', 'snapping_bite',   'Snapping Bite',   'fighting', 'derived', true, '{"div": 4, "parts": [["CO", 1], ["ST", 1], ["AG", 1], ["PR", 1]]}', 845, 'mossback_elder'),
  ('126794dd-25ff-47d2-a436-724499733365', 'lure',            'Lure',            'fighting', 'derived', true, '{"div": 4, "parts": [["CG", 2], ["FO", 1], ["IN", 1]]}', 850, 'gloam_wisp'),
  ('126794dd-25ff-47d2-a436-724499733365', 'cold_touch',      'Cold Touch',      'fighting', 'derived', true, '{"div": 4, "parts": [["ST", 2], ["AG", 1], ["FO", 1]]}', 855, 'gloam_wisp'),
  ('126794dd-25ff-47d2-a436-724499733365', 'gore',            'Gore',            'fighting', 'derived', true, '{"div": 4, "parts": [["CO", 1], ["ST", 2], ["AG", 1]]}', 860, 'thornfield_boar'),
  ('126794dd-25ff-47d2-a436-724499733365', 'charge',          'Charge',          'fighting', 'derived', true, '{"div": 3, "parts": [["CO", 1], ["AG", 1], ["PR", 1]]}', 865, 'thornfield_boar');

-- 2. Each action names the skill it rolls.
ALTER TABLE public.rpg_creature_actions ADD COLUMN IF NOT EXISTS skill_key text;
ALTER TABLE public.rpg_creature_actions ADD CONSTRAINT rpg_creature_actions_skill_key_fkey
  FOREIGN KEY (agency_id, skill_key) REFERENCES public.rpg_stat_definitions (agency_id, key) ON UPDATE CASCADE;
COMMENT ON COLUMN public.rpg_creature_actions.skill_key IS 'The skill this action rolls (rpg_stat_definitions.key), a stat the card has. A creature made from the card rolls its own number for it (Claw 10 on the Bramblemaw''s sheet). The printed skill column is what a fight reads until fights make creatures from their cards.';

CREATE OR REPLACE FUNCTION public.rpg_creature_actions_skill_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- An action can only roll a skill its card has: a shared one, or one that belongs to the card or a card above it
-- (rpg_template_stat_defs). The Bramblemaw's Claw may roll Claw; the Boar's Gore may not.
DECLARE v_card text; v_name text;
BEGIN
  IF NEW.skill_key IS NULL THEN RETURN NEW; END IF;
  SELECT c.key, c.name INTO v_card, v_name FROM public.rpg_creatures c WHERE c.id = NEW.creature_id;
  IF NOT EXISTS (SELECT 1 FROM public.rpg_template_stat_defs(v_card) d WHERE d.key = NEW.skill_key) THEN
    RAISE EXCEPTION '% on the % card cannot roll %: the card does not have that skill', NEW.name, v_name, NEW.skill_key;
  END IF;
  RETURN NEW;
END;
$function$;
DROP TRIGGER IF EXISTS rpg_creature_actions_skill_check ON public.rpg_creature_actions;
CREATE TRIGGER rpg_creature_actions_skill_check BEFORE INSERT OR UPDATE OF skill_key, creature_id ON public.rpg_creature_actions
  FOR EACH ROW EXECUTE FUNCTION public.rpg_creature_actions_skill_check();
REVOKE ALL ON FUNCTION public.rpg_creature_actions_skill_check() FROM PUBLIC, anon, authenticated;

UPDATE public.rpg_creature_actions a SET skill_key = m.skill_key
  FROM (VALUES ('bramblemaw', 'Claw', 'claw'), ('bramblemaw', 'Bite', 'bite'), ('bramblemaw', 'Rending Swipe', 'rending_swipe'),
               ('bramblemaw', 'Briar Roar', 'briar_roar'), ('bramblemaw', 'Grasping Roots', 'grasping_roots'),
               ('ashwing_harrier', 'Talon Dive', 'talon_dive'), ('ashwing_harrier', 'Hunting Screech', 'hunting_screech'),
               ('mossback_elder', 'Shell Slam', 'shell_slam'), ('mossback_elder', 'Snapping Bite', 'snapping_bite'),
               ('gloam_wisp', 'Lure', 'lure'), ('gloam_wisp', 'Cold Touch', 'cold_touch'),
               ('thornfield_boar', 'Gore', 'gore'), ('thornfield_boar', 'Charge', 'charge')) AS m(card, action, skill_key)
  JOIN public.rpg_creatures c ON c.key = m.card AND c.agency_id = '126794dd-25ff-47d2-a436-724499733365'
 WHERE a.creature_id = c.id AND a.name = m.action;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.rpg_creature_actions WHERE skill_key IS NOT NULL) <> 13
     OR EXISTS (SELECT 1 FROM public.rpg_creature_actions WHERE skill IS NOT NULL AND skill_key IS NULL) THEN
    RAISE EXCEPTION 'every action that rolls must name its skill';
  END IF;
END $$;

-- A contest names the attacker's stat by its sheet key: Strength is ST (the creature branch of rpg_participant_value
-- already reads ST as the card's strength).
UPDATE public.rpg_creature_actions
   SET effect = jsonb_set(effect, '{contest,skill_key}', '"ST"')
 WHERE effect #>> '{contest,skill_key}' = 'strength';

-- 3. Blueprints.
UPDATE public.rpg_creatures c SET blueprint = m.bp::jsonb, updated_at = now()
  FROM (VALUES
    ('bramblemaw', '{"CG":0,"LO":0,"JO":0,"PE":0,"PA":0,"KI":0,"GO":0,"FA":0,"GE":0,"SC":0,"FE":12,"HT":12,"MI":10,"SR":10,"RA":8,"CR":12,"WK":11,"TR":10,"BU":12,"RK":5,"IN":6,"FO":5,"ME":8,"PR":8,"ST":10,"AG":7,"TO":43,"CO":{"points":36000},"EE":{"points":15000},"claw":{"points":19000},"bite":{"points":19000}}'),
    ('ashwing_harrier', '{"FE":0,"HT":0,"MI":0,"SR":0,"RA":0,"CR":0,"WK":0,"TR":0,"BU":0,"RK":0,"IN":{"divisor":20},"PR":{"divisor":4},"ST":{"divisor":8},"AG":{"divisor":5.5},"TO":{"divisor":5},"CO":{"points":13000},"EE":{"points":28000},"hunting_screech":{"points":11000}}'),
    ('mossback_elder', '{"FE":0,"HT":0,"MI":0,"SR":0,"RA":0,"CR":0,"WK":0,"TR":0,"BU":0,"RK":0,"IN":{"divisor":20},"ST":{"divisor":4},"AG":{"divisor":33},"TO":{"divisor":1},"CO":{"points":56000},"EE":{"points":105000},"shell_slam":{"points":28000},"snapping_bite":{"points":19000}}'),
    ('gloam_wisp', '{"CG":0,"LO":0,"JO":0,"PE":0,"PA":0,"KI":0,"GO":0,"FA":0,"GE":0,"SC":0,"FE":{"divisor":5},"HT":{"divisor":5},"MI":{"divisor":5},"SR":{"divisor":5},"RA":{"divisor":5},"CR":{"divisor":5},"WK":{"divisor":5},"TR":{"divisor":5},"BU":{"divisor":5},"RK":{"divisor":5},"ST":{"divisor":40},"AG":{"divisor":6},"TO":{"divisor":6},"CO":{"points":40000},"EE":{"points":24000},"lure":{"points":25000},"cold_touch":{"points":11000}}'),
    ('thornfield_boar', '{"FE":0,"HT":0,"MI":0,"SR":0,"RA":0,"CR":0,"WK":0,"TR":0,"BU":0,"RK":0,"IN":{"divisor":20},"ST":{"divisor":5},"AG":{"divisor":7},"TO":{"divisor":3},"CO":{"points":27000},"EE":{"points":20000},"charge":{"points":13000}}')
  ) AS m(card, bp)
 WHERE c.key = m.card AND c.agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 4a. The GM card says which skill each action rolls.
DO $$
DECLARE v_def text := pg_get_functiondef('public.rpg_creature_card(uuid)'::regprocedure);
        v_old text := $o$        'skill', a.skill, 'against', a.against,$o$;
        v_new text := $n$        'skill', a.skill, 'skill_key', a.skill_key,
        'skill_name', (SELECT d.name FROM public.rpg_stat_definitions d
                        WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND d.key = a.skill_key),
        'against', a.against,$n$;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'rpg_creature_card: anchor not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $$;

-- 4b. The Rules tab: which card a card-only skill belongs to; a hidden card's skills stay off the players' page.
CREATE OR REPLACE FUNCTION public.rpg_rules_page(p_max_level integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The Rules tab in one read: the rule cards, every stat and how it is figured, the level costs and the settings.
-- A stat that belongs to one card (the Bramblemaw's Claw) carries that card's name, and players see it only once the
-- card has been shown to them.
SELECT public.require_login('family');
  WITH gm AS (SELECT public.family_is_parent() AS is_gm),
       names AS (
         SELECT coalesce(jsonb_object_agg(d.key, d.name), '{}'::jsonb) AS m
         FROM public.rpg_stat_definitions d
         WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365')
  SELECT jsonb_build_object(
    'is_gm', gm.is_gm,
    'rules', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                'key', r.key, 'title', r.title, 'body', r.body, 'source', r.source, 'section', r.section)
                ORDER BY r.sort_order, r.key), '[]'::jsonb)
              FROM public.rpg_rules r
              WHERE r.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
    'stats', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                'key', d.key, 'name', d.name, 'abbr', d.abbr, 'grp', d.grp, 'kind', d.kind,
                'trainable', d.trainable, 'default_value', d.default_value,
                'card_key', d.template_key, 'card_name', c.name,
                'formula_text', public.rpg_formula_text(d.formula, names.m))
                ORDER BY d.sort_order, d.key), '[]'::jsonb)
              FROM public.rpg_stat_definitions d CROSS JOIN names
              LEFT JOIN public.rpg_creatures c ON c.agency_id = d.agency_id AND c.key = d.template_key
              WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365'
                AND (d.template_key IS NULL OR gm.is_gm OR (c.is_active AND c.shown_to_players))),
    'level_costs', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                      'level', l, 'next_level', l + 1, 'points', public.rpg_level_cost(l))
                      ORDER BY l), '[]'::jsonb)
                    FROM generate_series(0, greatest(coalesce(p_max_level, 30), 1)) AS l),
    'crit_chance', public.rpg_setting('crit_chance'),
    'default_difficulty', public.rpg_setting('default_difficulty'),
    'level_cost_multiplier', public.rpg_setting('level_cost_multiplier'),
    'settings', CASE WHEN gm.is_gm THEN
                  (SELECT coalesce(jsonb_agg(jsonb_build_object('key', s.key, 'value', s.value, 'label', s.label)
                     ORDER BY s.key), '[]'::jsonb)
                   FROM public.rpg_settings s
                   WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365')
                ELSE '[]'::jsonb END)
  FROM gm
  WHERE (SELECT public.rpg_can_play());
$function$;

-- 4c. A stale line in rpg_new_character's notes (cards no longer carry ranges).
DO $$
DECLARE v_def text := pg_get_functiondef('public.rpg_new_character(text, uuid, boolean, text)'::regprocedure);
        v_old text := $o$-- rounded up (a 47 makes 5); a card with ranges or fixed numbers rolls inside them.$o$;
        v_new text := $n$-- rounded up (a 47 makes 5); another card rolls with its own dividers and set numbers, then its experience is
-- spent by rpg_apply_experience (a Thornfield Boar rolls Toughness d100 ÷ 3, so a 47 makes 16).$n$;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'rpg_new_character: anchor not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $$;

-- 4d. The rule card (the admin manual page follows by trigger).
UPDATE public.rpg_rules SET body = $b$A creature is made from its card the same way a character is made from the Human card (see How a Character is Rolled). Its Spirit, Mind and Body traits roll with the card's dividers, or take the card's set numbers if it is a boss, and then the card's experience is spent up the same level ladder. From there its sheet is figured with exactly the same formulas as yours. Nothing on a creature is figured any other way.
*A Thornfield Boar rolls Toughness d100 ÷ 3, rounded up: a 47 makes 16. Its Physical Vitality is 3 × Toughness 16 + 2 × Strength 10 = 68, and its Integrity is 16 ÷ 5 = 3, rounded down.*

The numbers a fight uses are the same ones a character has: Evade Enemy (what you roll against to hit it), Courage (what you roll against to frighten, trick or persuade it), Strength, Agility, Physical Vitality, Integrity, and physical and spiritual energy.
*The Bramblemaw is a boss, so every trait is set, and every Bramblemaw has Evade Enemy 8, Courage 10, Strength 10, Agility 7, Physical Vitality 149 and Integrity 8.*

A creature also has skills only its card carries, built from its traits like any other skill, and each attack on its card rolls one of them.
*The Bramblemaw's Claw is (Courage 10 + 2 × Strength 10 + Agility 7) ÷ 4 = 9, rounded down, and its card's experience adds one level: Claw 10. It rolls 10 against your Evade Enemy × 2: Evade Enemy 5 → difficulty 10 → needs 50 or more.*

Hitting it: your weapon skill against its Evade Enemy × 2, and what gets through must clear its Integrity.
*Sword 6 against Evade Enemy 8: difficulty 16, needs 73 or more. A roll of 90 does 17, past its Integrity of 8. A roll of 80 does 7 and bounces off.* Asleep or held it cannot act, so its Evade Enemy × 1.
Persuading, tricking or frightening it: your skill against its Courage × 2. Sneaking past it: Quiet Movement or Blend With Surroundings against its Vision × 2. Spotting it hidden: Vision or Listening against its Blend With Surroundings × 2.

Until fights make each creature from its card, a fight still uses the numbers printed on the card, with no Integrity. They match a typical creature made from that card.

The d20 stat block printed on a card (armor class, hit points, saving throws, +to hit, DCs) is kept for reading and flavor. It does not drive any roll.$b$,
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'creature_conversion';

