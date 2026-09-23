-- Roleplaying module (Family area). Step 1 of the build plan (persistent_memory spec
-- "Roleplaying module — build plan", project roleplaying).
-- Prefix rpg_ because rp_ already belongs to Retention Points.
-- Sources: admin manual > Outside Agency > Roleplaying (rules, verbatim below) and
-- Drive > Shared > Roleplaying > Character Generator (every stat formula below).
-- Access: the Family Hub login (role family) and site admins/owner, same as Family and Inventory.

-- ───────────────────────── tables ─────────────────────────
CREATE TABLE IF NOT EXISTS public.rpg_settings (
  agency_id  uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365',
  key        text NOT NULL,
  value      numeric NOT NULL,
  label      text NOT NULL,
  PRIMARY KEY (agency_id, key)
);

CREATE TABLE IF NOT EXISTS public.rpg_stat_definitions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id     uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365',
  key           text NOT NULL,
  name          text NOT NULL,
  abbr          text,
  grp           text NOT NULL CHECK (grp IN ('strength','physical','spiritual','ability','fighting')),
  kind          text NOT NULL CHECK (kind IN ('rolled','derived','fixed')),
  trainable     boolean NOT NULL DEFAULT false,   -- gains skill points and levels when rolled
  formula       jsonb,                             -- {"parts":[["LO",1],["JO",3]],"div":6} -> floor(sum/div)
  default_value integer NOT NULL DEFAULT 0,        -- fixed stats start here (Sword of the Spirit = 1)
  sort_order    integer NOT NULL DEFAULT 0,
  UNIQUE (agency_id, key)
);

CREATE TABLE IF NOT EXISTS public.rpg_rules (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id  uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365',
  key        text NOT NULL,
  title      text NOT NULL,
  body       text NOT NULL,
  source     text NOT NULL CHECK (source IN ('manual','sheet','peter','engine')),
  sort_order integer NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, key)
);

CREATE TABLE IF NOT EXISTS public.rpg_characters (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id       uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365',
  name            text NOT NULL,
  kid_id          uuid REFERENCES public.family_kids(id) ON DELETE SET NULL,
  is_npc          boolean NOT NULL DEFAULT false,
  inputs          jsonb NOT NULL DEFAULT '{}'::jsonb,   -- rolled and fixed stat values by stat key
  vitality_damage integer NOT NULL DEFAULT 0 CHECK (vitality_damage >= 0),
  platinum        integer NOT NULL DEFAULT 0,
  gold            integer NOT NULL DEFAULT 0,
  silver          integer NOT NULL DEFAULT 0,
  copper          integer NOT NULL DEFAULT 0,
  color           text NOT NULL DEFAULT '#737A59',
  notes           text,
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.rpg_character_skills (
  character_id  uuid NOT NULL REFERENCES public.rpg_characters(id) ON DELETE CASCADE,
  stat_key      text NOT NULL,
  skill_points  numeric NOT NULL DEFAULT 0,
  earned_levels integer NOT NULL DEFAULT 0,
  PRIMARY KEY (character_id, stat_key)
);

CREATE TABLE IF NOT EXISTS public.rpg_items (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id    uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365',
  character_id uuid NOT NULL REFERENCES public.rpg_characters(id) ON DELETE CASCADE,
  name         text NOT NULL,
  stat_key     text,                                  -- which stat the bonus lands on
  bonus        integer NOT NULL DEFAULT 0,
  uses_left    integer,                               -- null = unlimited
  equipped     boolean NOT NULL DEFAULT true,
  notes        text,
  sort_order   integer NOT NULL DEFAULT 0,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.rpg_rolls (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id      uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365',
  character_id   uuid NOT NULL REFERENCES public.rpg_characters(id) ON DELETE CASCADE,
  session_id     uuid,                                -- play session (step 5)
  stat_key       text NOT NULL,
  skill          numeric NOT NULL,
  difficulty     numeric NOT NULL,
  needed         numeric NOT NULL,
  critical_at    numeric NOT NULL,
  roll           integer NOT NULL,
  result         text NOT NULL CHECK (result IN ('C','Y','')),
  points_awarded numeric NOT NULL DEFAULT 0,
  level_before   integer NOT NULL,
  level_after    integer NOT NULL,
  parent_roll_id uuid REFERENCES public.rpg_rolls(id) ON DELETE SET NULL,  -- the critical this extra roll follows
  extra_pending  boolean NOT NULL DEFAULT false,      -- a critical waiting for its additional roll
  label          text,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS rpg_rolls_character_idx ON public.rpg_rolls (character_id, created_at DESC);

DROP TRIGGER IF EXISTS rpg_characters_set_updated_at ON public.rpg_characters;
CREATE TRIGGER rpg_characters_set_updated_at BEFORE UPDATE ON public.rpg_characters
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
DROP TRIGGER IF EXISTS rpg_rules_set_updated_at ON public.rpg_rules;
CREATE TRIGGER rpg_rules_set_updated_at BEFORE UPDATE ON public.rpg_rules
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ───────────────────────── access ─────────────────────────
CREATE OR REPLACE FUNCTION public.rpg_can_play()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.auth_is_family() OR public.family_is_parent();
$$;

ALTER TABLE public.rpg_settings         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rpg_stat_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rpg_rules            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rpg_characters       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rpg_character_skills ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rpg_items            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rpg_rolls            ENABLE ROW LEVEL SECURITY;

-- reference tables: the household reads, parents edit
DROP POLICY IF EXISTS rpg_settings_play_read ON public.rpg_settings;
CREATE POLICY rpg_settings_play_read ON public.rpg_settings FOR SELECT TO authenticated USING (agency_id = '126794dd-25ff-47d2-a436-724499733365' AND (SELECT public.rpg_can_play()));
DROP POLICY IF EXISTS rpg_settings_parents_all ON public.rpg_settings;
CREATE POLICY rpg_settings_parents_all ON public.rpg_settings FOR ALL TO authenticated USING (agency_id = '126794dd-25ff-47d2-a436-724499733365' AND (SELECT public.family_is_parent())) WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365' AND (SELECT public.family_is_parent()));
DROP POLICY IF EXISTS rpg_stat_definitions_play_read ON public.rpg_stat_definitions;
CREATE POLICY rpg_stat_definitions_play_read ON public.rpg_stat_definitions FOR SELECT TO authenticated USING (agency_id = '126794dd-25ff-47d2-a436-724499733365' AND (SELECT public.rpg_can_play()));
DROP POLICY IF EXISTS rpg_stat_definitions_parents_all ON public.rpg_stat_definitions;
CREATE POLICY rpg_stat_definitions_parents_all ON public.rpg_stat_definitions FOR ALL TO authenticated USING (agency_id = '126794dd-25ff-47d2-a436-724499733365' AND (SELECT public.family_is_parent())) WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365' AND (SELECT public.family_is_parent()));
DROP POLICY IF EXISTS rpg_rules_play_read ON public.rpg_rules;
CREATE POLICY rpg_rules_play_read ON public.rpg_rules FOR SELECT TO authenticated USING (agency_id = '126794dd-25ff-47d2-a436-724499733365' AND (SELECT public.rpg_can_play()));
DROP POLICY IF EXISTS rpg_rules_parents_all ON public.rpg_rules;
CREATE POLICY rpg_rules_parents_all ON public.rpg_rules FOR ALL TO authenticated USING (agency_id = '126794dd-25ff-47d2-a436-724499733365' AND (SELECT public.family_is_parent())) WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365' AND (SELECT public.family_is_parent()));

-- play tables: the whole household reads and writes
DROP POLICY IF EXISTS rpg_characters_play_all ON public.rpg_characters;
CREATE POLICY rpg_characters_play_all ON public.rpg_characters FOR ALL TO authenticated USING (agency_id = '126794dd-25ff-47d2-a436-724499733365' AND (SELECT public.rpg_can_play())) WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365' AND (SELECT public.rpg_can_play()));
DROP POLICY IF EXISTS rpg_character_skills_play_all ON public.rpg_character_skills;
CREATE POLICY rpg_character_skills_play_all ON public.rpg_character_skills FOR ALL TO authenticated USING ((SELECT public.rpg_can_play())) WITH CHECK ((SELECT public.rpg_can_play()));
DROP POLICY IF EXISTS rpg_items_play_all ON public.rpg_items;
CREATE POLICY rpg_items_play_all ON public.rpg_items FOR ALL TO authenticated USING (agency_id = '126794dd-25ff-47d2-a436-724499733365' AND (SELECT public.rpg_can_play())) WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365' AND (SELECT public.rpg_can_play()));
DROP POLICY IF EXISTS rpg_rolls_play_all ON public.rpg_rolls;
CREATE POLICY rpg_rolls_play_all ON public.rpg_rolls FOR ALL TO authenticated USING (agency_id = '126794dd-25ff-47d2-a436-724499733365' AND (SELECT public.rpg_can_play())) WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365' AND (SELECT public.rpg_can_play()));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.rpg_settings, public.rpg_stat_definitions, public.rpg_rules,
  public.rpg_characters, public.rpg_character_skills, public.rpg_items, public.rpg_rolls TO authenticated;

-- ───────────────────────── settings ─────────────────────────
INSERT INTO public.rpg_settings (key, value, label) VALUES
  ('crit_chance',            0.10, 'Critical chance: the top share of the success range that counts as a critical'),
  ('level_cost_multiplier',  1000, 'Skill points to level up = this × (old level + new level)'),
  ('default_difficulty',     5,    'Difficulty a roll uses when nobody sets one'),
  ('strength_roll_max',      100,  'Die rolled for each strength when a character is made (d100)'),
  ('strength_roll_divisor',  10,   'The strength roll is divided by this and rounded up'),
  ('damage_divisor',         1,    'Damage = (attack roll − defense roll) ÷ this')
ON CONFLICT (agency_id, key) DO UPDATE SET value = EXCLUDED.value, label = EXCLUDED.label;

-- ───────────────────────── stat definitions (from the Character Generator sheet) ─────────────────────────
INSERT INTO public.rpg_stat_definitions (key, name, abbr, grp, kind, trainable, formula, default_value, sort_order) VALUES
  -- Strengths (rolled)
  ('LO','Love','LO','strength','rolled',false,NULL,0,10),
  ('JO','Joy','JO','strength','rolled',false,NULL,0,20),
  ('PE','Peace','PE','strength','rolled',false,NULL,0,30),
  ('PA','Patience','PA','strength','rolled',false,NULL,0,40),
  ('KI','Kindness','KI','strength','rolled',false,NULL,0,50),
  ('GO','Goodness','GO','strength','rolled',false,NULL,0,60),
  ('FA','Faithfulness','FA','strength','rolled',false,NULL,0,70),
  ('GE','Gentleness','GE','strength','rolled',false,NULL,0,80),
  ('SC','Self-Control','SC','strength','rolled',false,NULL,0,90),
  -- Physical Attributes
  ('PV','Physical Vitality','PV','physical','derived',false,'{"parts":[["LO",1],["JO",1],["PE",1],["PA",1],["KI",1],["GO",1],["FA",1],["GE",1],["SC",1]],"div":2}',0,100),
  ('ST','Strength','ST','physical','rolled',false,NULL,0,110),
  ('AG','Agility','AG','physical','rolled',false,NULL,0,120),
  -- Spiritual Attributes
  ('BT','Belt of Truth','BT','spiritual','derived',false,'{"parts":[["KN",1]],"div":1}',0,200),
  ('BR','Breastplate of Righteousness','BR','spiritual','derived',false,'{"parts":[["GO",1]],"div":1}',0,210),
  ('SF','Shield of Faith','SF','spiritual','derived',false,'{"parts":[["LO",1],["JO",1],["PE",1],["PA",1],["KI",1],["GO",1],["FA",1],["GE",1],["SC",1]],"div":9}',0,220),
  ('HS','Helmet of Salvation','HS','spiritual','derived',false,'{"parts":[["HO",1]],"div":1}',0,230),
  ('SS','Sword of the Spirit','SS','spiritual','fixed',false,NULL,1,240),
  ('BGP','Boots of the Gospel of Peace','BGP','spiritual','derived',false,'{"parts":[["LO",1],["JO",1],["PE",1],["GO",1],["FA",1]],"div":5}',0,250),
  -- Character Abilities
  ('CO','Courage','CO','ability','derived',true,'{"parts":[["LO",1],["JO",1],["GO",1],["FA",1],["SC",1]],"div":5}',0,300),
  ('EN','Endurance','EN','ability','derived',true,'{"parts":[["JO",1],["PE",1],["PA",2],["FA",1],["SC",2]],"div":7}',0,310),
  ('HO','Hope','HO','ability','derived',true,'{"parts":[["JO",3],["PE",1],["PA",1],["FA",1]],"div":6}',0,320),
  ('KN','Knowledge','KN','ability','derived',true,'{"parts":[["JO",1],["PA",1],["GO",1],["FA",1]],"div":4}',0,330),
  ('LIS','Listening','LIS','ability','derived',true,'{"parts":[["PE",2],["PA",1],["SC",1]],"div":4}',0,340),
  ('QM','Quiet Movement','QM','ability','derived',true,'{"parts":[["PE",1],["PA",1],["SC",1],["EN",1]],"div":4}',0,350),
  ('VIS','Vision','VIS','ability','derived',true,'{"parts":[["PA",1],["FA",1],["HO",1]],"div":3}',0,360),
  ('WIS','Wisdom','WIS','ability','derived',true,'{"parts":[["LO",3],["JO",1],["PE",1],["KI",1],["GO",1],["GE",1]],"div":8}',0,370),
  ('BWS','Blend With Surroundings','BWS','ability','derived',true,'{"parts":[["SC",2],["PA",1],["EN",2]],"div":5}',0,380),
  ('CL','Climbing','CL','ability','derived',true,'{"parts":[["JO",1],["PE",1],["PA",1],["SC",2],["EN",1],["CO",1]],"div":7}',0,390),
  ('CA','Communicate with Animals','CA','ability','derived',true,'{"parts":[["JO",1],["KI",1],["GE",1]],"div":3}',0,400),
  ('HE','Hatred of Evil','HE','ability','derived',true,'{"parts":[["LO",1],["GO",3],["FA",2],["KN",1],["WIS",1]],"div":8}',0,410),
  ('MC','Merciful Compassion','MC','ability','derived',true,'{"parts":[["LO",1],["PA",1],["KI",2],["GE",1]],"div":5}',0,420),
  ('PF','Persuade Foe','PF','ability','derived',true,'{"parts":[["FA",2],["SC",1],["KN",1],["WIS",2],["CO",1]],"div":7}',0,430),
  ('RME','Righteously Mingle with Evil','RME','ability','derived',true,'{"parts":[["LIS",1],["SB",1],["RT",1],["GE",1],["HE",2],["KI",1]],"div":7}',0,440),
  ('SE','Sense Evil','SE','ability','derived',true,'{"parts":[["GO",2],["KN",1],["CO",1]],"div":4}',0,450),
  ('TL','Talk with Locals','TL','ability','derived',true,'{"parts":[["LO",1],["KI",2],["GO",1],["GE",2]],"div":6}',0,460),
  ('TE','Track Enemy','TE','ability','derived',true,'{"parts":[["JO",1],["PA",1],["SC",1]],"div":3}',0,470),
  ('WM','Water Movement','WM','ability','derived',true,'{"parts":[["JO",1],["SC",1],["EN",2],["CO",1]],"div":5}',0,480),
  ('EE','Evade Enemy','EE','ability','derived',true,'{"parts":[["PE",1],["PA",1],["SC",1]],"div":3}',0,490),
  ('RFI','Recover from Injury','RFI','ability','derived',true,'{"parts":[["HO",3],["CO",1],["EN",1]],"div":5}',0,500),
  ('RT','Resist Torture','RT','ability','derived',true,'{"parts":[["JO",1],["FA",2],["SC",1],["HO",1],["CO",1],["EN",1]],"div":7}',0,510),
  ('TA','Train Animals','TA','ability','fixed',true,NULL,0,520),
  ('PROV','Providence','PROV','ability','derived',true,'{"parts":[["HO",1],["SF",1]],"div":2}',0,530),
  ('ATD','Attention to Detail','ATD','ability','fixed',true,NULL,0,540),
  -- Fighting
  ('SB','Solo Battle','SB','fighting','derived',true,'{"parts":[["PE",1],["EN",1],["CO",2]],"div":4}',0,600),
  ('battle_axe','Battle Axe',NULL,'fighting','derived',true,'{"parts":[["HO",1],["CO",1],["EN",1],["HE",1],["ST",1]],"div":5}',0,610),
  ('crossbow','Crossbow',NULL,'fighting','derived',true,'{"parts":[["HO",1],["VIS",1],["ST",1],["PA",1]],"div":4}',0,620),
  ('dagger','Dagger',NULL,'fighting','derived',true,'{"parts":[["CO",1],["SC",1],["SB",1],["AG",1]],"div":4}',0,630),
  ('flail','Flail',NULL,'fighting','derived',true,'{"parts":[["HO",1],["CO",1],["EN",1]],"div":3}',0,640),
  ('hand_axe','Hand Axe',NULL,'fighting','derived',true,'{"parts":[["HO",1],["CO",1],["SB",1]],"div":3}',0,650),
  ('hand_to_hand','Hand-to-Hand Battle',NULL,'fighting','derived',true,'{"parts":[["SC",1],["CO",1],["EN",1],["SB",1],["ST",1],["AG",1]],"div":6}',0,660),
  ('lance','Lance',NULL,'fighting','derived',true,'{"parts":[["CO",1],["EN",1],["SE",1],["SB",1]],"div":4}',0,670),
  ('longbow','Longbow',NULL,'fighting','derived',true,'{"parts":[["HO",1],["VIS",1],["ST",1],["QM",1]],"div":4}',0,680),
  ('military_fork','Military Fork',NULL,'fighting','derived',true,'{"parts":[["CO",1],["EN",1],["SE",1],["SC",1]],"div":4}',0,690),
  ('quarterstaff','Quarterstaff',NULL,'fighting','derived',true,'{"parts":[["HO",1],["CO",1],["SB",1],["AG",1]],"div":4}',0,700),
  ('sling','Sling',NULL,'fighting','derived',true,'{"parts":[["HO",1],["CO",1],["SC",1]],"div":3}',0,710),
  ('spear','Spear',NULL,'fighting','derived',true,'{"parts":[["CO",1],["EN",1],["SE",1],["SB",1]],"div":4}',0,720),
  ('sword','Sword',NULL,'fighting','derived',true,'{"parts":[["CO",1],["EN",1],["SB",1],["AG",1]],"div":4}',0,730),
  ('war_hammer','War Hammer',NULL,'fighting','derived',true,'{"parts":[["HO",1],["CO",1],["EN",1],["HE",1]],"div":4}',0,740),
  ('hurling','Hurling - Weapons',NULL,'fighting','derived',true,'{"parts":[["AG",1],["ST",1],["VIS",1],["HO",1]],"div":4}',0,750),
  ('tossing','Tossing - Objects',NULL,'fighting','derived',true,'{"parts":[["AG",1],["ST",1],["VIS",1],["HO",1]],"div":4}',0,760),
  ('healing_spiritual','Healing - Spiritual',NULL,'fighting','derived',true,'{"parts":[["HO",3],["SF",1],["BR",1]],"div":5}',0,770),
  ('healing_physical','Healing - Physical',NULL,'fighting','derived',true,'{"parts":[["healing_spiritual",5],["KN",1],["WIS",1]],"div":7}',0,780)
ON CONFLICT (agency_id, key) DO UPDATE SET name = EXCLUDED.name, abbr = EXCLUDED.abbr, grp = EXCLUDED.grp, kind = EXCLUDED.kind,
  trainable = EXCLUDED.trainable, formula = EXCLUDED.formula, default_value = EXCLUDED.default_value, sort_order = EXCLUDED.sort_order;

-- ───────────────────────── rules (manual text verbatim; sheet and Peter rulings marked by source) ─────────────────────────
INSERT INTO public.rpg_rules (key, title, body, source, sort_order) VALUES
  ('critical_rolls', 'Critical Rolls',
   E'Every critical roll will prompt an additional roll.\n\nAdditional rolls can add to damage inflicted or treasure discovered or any other success results.', 'manual', 10),
  ('skill_gain', 'Skill Gain',
   E'Every roll of a skill (including additional rolls after rolling a critical roll) will grant skill points equal to the roll multiplied by the ratio of the character to the difficulty. *For example, a character with a climbing skill of 10 will increase their climbing skill at 1.5 times the normal rate when climbing a surface with a difficulty of 15.*\n\nA skill will increase to the next level when skill points have been earned equal to 1000 times the sum of the old level AND the new level. *For example, Advancing to level 12 will require 23k skill points (11k skill points + 12k skill points)*\n\nCharacters can train in a skill by using that skill, though time and resources may limit training. *For example, hunger may set in or training with a tutor may cost money.*\n\nAbilities, strengths, and attributes can only be increased through special means.', 'manual', 20),
  ('tutors', 'Tutors',
   E'Tutors (or their more advanced version of masters) can be found throughout the game. In exchange for money or other valuables, they may be willing to spend their time teaching a skill.\n\nWhen training under a tutor, skill points are multiplied by the tutor''s skill as a percent of the learner''s skill. *For example, a tutor with a skill level of 15 will increase the skill of a learner with a skill level of 10 at 1.5 times the normal rate.*\n\nTutors typically charge gold equal to their skill as a percent of the learner''s skill. E.g. the above tutor will typically charge 1.5 gold coins for every training roll.', 'manual', 30),
  ('currency', 'Currency & Trade',
   E'Currency in the game largely revolves around coins. Base exchange rates are simple, though some merchants may attempt to exchange at a less favorable rate:\n\n- 1 Platinum = 100 Gold\n- 1 Gold = 100 Silver\n- 1 Silver = 100 Copper\n\nGems and other valuables can be found and sold for coins.', 'manual', 40),
  ('rolling_pc', 'Rolling a Player Character',
   'Roll a d100 and divide by ten for each of the strengths and let the file calculate the rest.', 'manual', 50),
  ('npcs', 'NPCs',
   'Base NPCs can be found below, though they can also be rolled like a player character and advanced automatically.', 'manual', 60),
  ('roll_check', 'Roll Check',
   E'Needed = Difficulty ÷ (Difficulty + Skill) × 100.\nCritical = 100 − ((100 − Needed) × Critical Chance).\nRoll a d100. At or above Critical is a critical success (C). At or above Needed is a success (Y). Below Needed fails.\nCritical Chance is 10%. Difficulty is 5 unless the game master sets another.', 'sheet', 70),
  ('strength_roll', 'How a Character is Rolled',
   'Each of the nine strengths, plus Strength and Agility, rolls a d100 divided by 10 and rounded up, so every result is 1 to 10. Sword of the Spirit starts at 1. Everything else on the sheet is calculated from those numbers.', 'engine', 80),
  ('damage', 'Damage',
   'Damage is the difference between character rolls. Attacking character rolls attack, defending character rolls defense. Difference is the damage inflicted.', 'peter', 90),
  ('creature_conversion', 'Creature Cards at the Table',
   'Creature cards are written in the d20 style. In play they convert to the same d100 rolls the characters use: the to-hit bonus becomes the creature''s attack skill, armor class minus 10 becomes the difficulty to hit it, a save DC minus 10 becomes the difficulty of that save roll, and hit points stay as printed. Creatures roll against a character''s Evade Enemy.', 'peter', 100)
ON CONFLICT (agency_id, key) DO UPDATE SET title = EXCLUDED.title, body = EXCLUDED.body, source = EXCLUDED.source, sort_order = EXCLUDED.sort_order;

-- ───────────────────────── functions ─────────────────────────
CREATE OR REPLACE FUNCTION public.rpg_setting(p_key text)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT value FROM public.rpg_settings WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = p_key;
$$;

-- Needed and Critical for one skill against one difficulty. The sheet's D2/E2 columns.
CREATE OR REPLACE FUNCTION public.rpg_needed(p_skill numeric, p_difficulty numeric)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH n AS (
    SELECT CASE WHEN coalesce(p_difficulty,0) + coalesce(p_skill,0) <= 0 THEN 100::numeric
                ELSE coalesce(p_difficulty,0) / (coalesce(p_difficulty,0) + coalesce(p_skill,0)) * 100 END AS needed
  )
  SELECT jsonb_build_object(
    'needed',   round(needed, 2),
    'critical', round(100 - ((100 - needed) * public.rpg_setting('crit_chance')), 2))
  FROM n;
$$;

-- Skill points to go from p_level to p_level + 1. Manual: 1000 × (old level + new level).
CREATE OR REPLACE FUNCTION public.rpg_level_cost(p_level integer)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.rpg_setting('level_cost_multiplier') * (p_level + (p_level + 1));
$$;

-- Plain-English formula for the Rules tab and the sheet, built from the same definition the engine uses.
CREATE OR REPLACE FUNCTION public.rpg_formula_text(p_formula jsonb, p_names jsonb)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_formula IS NULL THEN NULL ELSE
    CASE WHEN coalesce((p_formula->>'div')::numeric, 1) > 1 THEN '(' ELSE '' END
    || (SELECT string_agg(CASE WHEN (e->>1)::numeric <> 1 THEN (e->>1) || ' × ' ELSE '' END || coalesce(p_names->>(e->>0), e->>0), ' + ' ORDER BY ord)
        FROM jsonb_array_elements(p_formula->'parts') WITH ORDINALITY AS t(e, ord))
    || CASE WHEN coalesce((p_formula->>'div')::numeric, 1) > 1 THEN ') ÷ ' || (p_formula->>'div') || ', rounded down' ELSE '' END
  END;
$$;

-- Rolls the inputs for a new character: every rolled stat = d100 ÷ 10 rounded up (1–10); fixed stats take their default.
CREATE OR REPLACE FUNCTION public.rpg_roll_inputs()
RETURNS jsonb LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(jsonb_object_agg(key,
    CASE WHEN kind = 'rolled'
         THEN ceil((floor(random() * public.rpg_setting('strength_roll_max')) + 1) / public.rpg_setting('strength_roll_divisor'))
         ELSE default_value END), '{}'::jsonb)
  FROM public.rpg_stat_definitions
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND kind IN ('rolled','fixed');
$$;

-- The whole sheet for one character: every stat with its value, where the value came from, and what a roll needs
-- at the given difficulty. Powers the Characters tab, the Rules tab and every roll.
CREATE OR REPLACE FUNCTION public.rpg_sheet(p_character_id uuid, p_difficulty numeric DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_c       record;
  v_d       record;
  v_vals    jsonb := '{}'::jsonb;
  v_bonus   jsonb;
  v_earned  jsonb;
  v_points  jsonb;
  v_names   jsonb;
  v_pass    integer := 0;
  v_moved   boolean;
  v_part    jsonb;
  v_total   numeric;
  v_ok      boolean;
  v_div     numeric;
  v_v       numeric;
  v_diff    numeric;
  v_nc      jsonb;
  v_stats   jsonb := '[]'::jsonb;
  v_kid     text;
  v_items   jsonb;
  v_pv      numeric;
BEGIN
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_c FROM public.rpg_characters WHERE id = p_character_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'character not found'; END IF;
  v_diff := coalesce(p_difficulty, public.rpg_setting('default_difficulty'));

  SELECT coalesce(jsonb_object_agg(x.stat_key, x.b), '{}'::jsonb) INTO v_bonus
  FROM (SELECT i.stat_key, sum(i.bonus) AS b FROM public.rpg_items i
        WHERE i.character_id = p_character_id AND i.equipped AND i.stat_key IS NOT NULL
          AND (i.uses_left IS NULL OR i.uses_left > 0)
        GROUP BY i.stat_key) x;
  SELECT coalesce(jsonb_object_agg(s.stat_key, s.earned_levels), '{}'::jsonb),
         coalesce(jsonb_object_agg(s.stat_key, s.skill_points), '{}'::jsonb)
    INTO v_earned, v_points
  FROM public.rpg_character_skills s WHERE s.character_id = p_character_id;
  SELECT coalesce(jsonb_object_agg(t.key, t.name), '{}'::jsonb) INTO v_names
  FROM public.rpg_stat_definitions t WHERE t.agency_id = v_c.agency_id;

  -- rolled and fixed stats come straight from the character
  FOR v_d IN SELECT * FROM public.rpg_stat_definitions WHERE agency_id = v_c.agency_id AND kind IN ('rolled','fixed') LOOP
    v_v := coalesce((v_c.inputs->>v_d.key)::numeric, v_d.default_value)
         + coalesce((v_bonus->>v_d.key)::numeric, 0) + coalesce((v_earned->>v_d.key)::numeric, 0);
    v_vals := v_vals || jsonb_build_object(v_d.key, v_v);
  END LOOP;

  -- derived stats, resolved in dependency order (a stat waits until every part it uses is known)
  LOOP
    v_pass := v_pass + 1; v_moved := false;
    FOR v_d IN SELECT * FROM public.rpg_stat_definitions WHERE agency_id = v_c.agency_id AND kind = 'derived' LOOP
      CONTINUE WHEN v_vals ? v_d.key;
      v_ok := true; v_total := 0;
      FOR v_part IN SELECT e FROM jsonb_array_elements(v_d.formula->'parts') e LOOP
        IF NOT (v_vals ? (v_part->>0)) THEN v_ok := false; EXIT; END IF;
        v_total := v_total + (v_vals->>(v_part->>0))::numeric * (v_part->>1)::numeric;
      END LOOP;
      CONTINUE WHEN NOT v_ok;
      v_div := coalesce((v_d.formula->>'div')::numeric, 1);
      v_v := floor(v_total / v_div)
           + coalesce((v_bonus->>v_d.key)::numeric, 0) + coalesce((v_earned->>v_d.key)::numeric, 0);
      v_vals := v_vals || jsonb_build_object(v_d.key, v_v);
      v_moved := true;
    END LOOP;
    EXIT WHEN NOT v_moved OR v_pass >= 12;
  END LOOP;

  FOR v_d IN SELECT * FROM public.rpg_stat_definitions WHERE agency_id = v_c.agency_id ORDER BY sort_order LOOP
    v_v := coalesce((v_vals->>v_d.key)::numeric, 0);
    v_nc := public.rpg_needed(v_v, v_diff);
    v_stats := v_stats || jsonb_build_object(
      'key', v_d.key, 'name', v_d.name, 'abbr', v_d.abbr, 'grp', v_d.grp, 'kind', v_d.kind, 'trainable', v_d.trainable,
      'value', v_v,
      'base', v_v - coalesce((v_bonus->>v_d.key)::numeric, 0) - coalesce((v_earned->>v_d.key)::numeric, 0),
      'item_bonus', coalesce((v_bonus->>v_d.key)::numeric, 0),
      'earned_levels', coalesce((v_earned->>v_d.key)::numeric, 0),
      'skill_points', round(coalesce((v_points->>v_d.key)::numeric, 0), 1),
      'next_level_cost', CASE WHEN v_d.trainable THEN public.rpg_level_cost(v_v::integer) ELSE NULL END,
      'needed', v_nc->'needed', 'critical', v_nc->'critical',
      'formula_text', public.rpg_formula_text(v_d.formula, v_names));
  END LOOP;

  SELECT k.name INTO v_kid FROM public.family_kids k WHERE k.id = v_c.kid_id;
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'stat_key', i.stat_key,
           'stat_name', v_names->>i.stat_key, 'bonus', i.bonus, 'uses_left', i.uses_left, 'equipped', i.equipped, 'notes', i.notes)
           ORDER BY i.sort_order, i.created_at), '[]'::jsonb)
    INTO v_items FROM public.rpg_items i WHERE i.character_id = p_character_id;
  v_pv := coalesce((v_vals->>'PV')::numeric, 0);

  RETURN jsonb_build_object(
    'id', v_c.id, 'name', v_c.name, 'kid_id', v_c.kid_id, 'kid_name', v_kid, 'is_npc', v_c.is_npc,
    'color', v_c.color, 'notes', v_c.notes, 'inputs', v_c.inputs,
    'vitality_max', v_pv, 'vitality_damage', v_c.vitality_damage, 'vitality_left', greatest(v_pv - v_c.vitality_damage, 0),
    'coins', jsonb_build_object('platinum', v_c.platinum, 'gold', v_c.gold, 'silver', v_c.silver, 'copper', v_c.copper),
    'difficulty', v_diff, 'crit_chance', public.rpg_setting('crit_chance'),
    'items', v_items, 'stats', v_stats);
END;
$$;

-- Makes a character: rolls the strengths on the server and saves them.
CREATE OR REPLACE FUNCTION public.rpg_new_character(p_name text, p_kid_id uuid DEFAULT NULL, p_is_npc boolean DEFAULT false)
RETURNS uuid LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id uuid;
  v_n  integer;
  v_palette text[] := ARRAY['#737A59','#A88B5F','#5E7A77','#6E5B7A','#A87A75','#255C99','#2E8B57','#D4A017'];
BEGIN
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF coalesce(btrim(p_name), '') = '' THEN RAISE EXCEPTION 'name required'; END IF;
  SELECT count(*) INTO v_n FROM public.rpg_characters WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';
  INSERT INTO public.rpg_characters (name, kid_id, is_npc, inputs, color)
  VALUES (btrim(p_name), p_kid_id, coalesce(p_is_npc, false), public.rpg_roll_inputs(), v_palette[(v_n % 8) + 1])
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- Rolls a fresh set of strengths for a character. Parents any time; the household only before the character has rolled anything.
CREATE OR REPLACE FUNCTION public.rpg_reroll_character(p_character_id uuid)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF NOT public.family_is_parent() AND EXISTS (SELECT 1 FROM public.rpg_rolls WHERE character_id = p_character_id) THEN
    RAISE EXCEPTION 'this character has already played; ask a parent to re-roll';
  END IF;
  UPDATE public.rpg_characters SET inputs = public.rpg_roll_inputs() WHERE id = p_character_id;
  RETURN public.rpg_sheet(p_character_id);
END;
$$;

-- Sets one rolled or fixed stat by hand (the "special means" in the manual). Parents only.
CREATE OR REPLACE FUNCTION public.rpg_set_input(p_character_id uuid, p_key text, p_value integer)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'parents only'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rpg_stat_definitions WHERE key = p_key AND kind IN ('rolled','fixed')) THEN
    RAISE EXCEPTION 'that stat is calculated, not set';
  END IF;
  UPDATE public.rpg_characters SET inputs = inputs || jsonb_build_object(p_key, p_value) WHERE id = p_character_id;
  RETURN public.rpg_sheet(p_character_id);
END;
$$;

-- Damage taken or healed. Negative p_delta heals. Vitality damage never goes below zero.
CREATE OR REPLACE FUNCTION public.rpg_adjust_vitality(p_character_id uuid, p_delta integer)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  UPDATE public.rpg_characters SET vitality_damage = greatest(vitality_damage + coalesce(p_delta, 0), 0) WHERE id = p_character_id;
  RETURN public.rpg_sheet(p_character_id);
END;
$$;

-- One roll of one stat. The server rolls the d100, applies the sheet's Needed/Critical, awards skill points
-- (manual: roll × difficulty ÷ skill), levels the skill up at 1000 × (old + new), and flags a critical so the
-- app can prompt the additional roll. p_parent_roll_id links an additional roll to the critical it follows.
CREATE OR REPLACE FUNCTION public.rpg_roll(p_character_id uuid, p_stat_key text, p_difficulty numeric DEFAULT NULL,
                                           p_label text DEFAULT NULL, p_parent_roll_id uuid DEFAULT NULL, p_session_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_sheet   jsonb;
  v_stat    jsonb;
  v_skill   numeric;
  v_diff    numeric;
  v_nc      jsonb;
  v_roll    integer;
  v_result  text;
  v_points  numeric := 0;
  v_before  integer;
  v_after   integer;
  v_cost    numeric;
  v_sp      numeric;
  v_earned  integer;
  v_id      uuid;
  v_agency  uuid;
BEGIN
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  v_diff := coalesce(p_difficulty, public.rpg_setting('default_difficulty'));
  IF v_diff < 0 THEN RAISE EXCEPTION 'difficulty cannot be negative'; END IF;
  v_sheet := public.rpg_sheet(p_character_id, v_diff);
  SELECT s INTO v_stat FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = p_stat_key;
  IF v_stat IS NULL THEN RAISE EXCEPTION 'unknown stat %', p_stat_key; END IF;
  v_skill := (v_stat->>'value')::numeric;
  v_nc := public.rpg_needed(v_skill, v_diff);
  v_roll := floor(random() * 100)::integer + 1;
  v_result := CASE WHEN v_roll >= (v_nc->>'critical')::numeric THEN 'C'
                   WHEN v_roll >= (v_nc->>'needed')::numeric THEN 'Y' ELSE '' END;
  v_before := v_skill::integer; v_after := v_before;

  IF (v_stat->>'trainable')::boolean THEN
    v_points := v_roll * (v_diff / greatest(v_skill, 1));
    INSERT INTO public.rpg_character_skills (character_id, stat_key) VALUES (p_character_id, p_stat_key)
      ON CONFLICT (character_id, stat_key) DO NOTHING;
    SELECT skill_points, earned_levels INTO v_sp, v_earned
      FROM public.rpg_character_skills WHERE character_id = p_character_id AND stat_key = p_stat_key FOR UPDATE;
    v_sp := v_sp + v_points;
    LOOP
      v_cost := public.rpg_level_cost(v_after);
      EXIT WHEN v_sp < v_cost;
      v_sp := v_sp - v_cost; v_earned := v_earned + 1; v_after := v_after + 1;
    END LOOP;
    UPDATE public.rpg_character_skills SET skill_points = v_sp, earned_levels = v_earned
     WHERE character_id = p_character_id AND stat_key = p_stat_key;
  END IF;

  SELECT agency_id INTO v_agency FROM public.rpg_characters WHERE id = p_character_id;
  INSERT INTO public.rpg_rolls (agency_id, character_id, session_id, stat_key, skill, difficulty, needed, critical_at,
                                roll, result, points_awarded, level_before, level_after, parent_roll_id, extra_pending, label)
  VALUES (v_agency, p_character_id, p_session_id, p_stat_key, v_skill, v_diff, (v_nc->>'needed')::numeric, (v_nc->>'critical')::numeric,
          v_roll, v_result, v_points, v_before, v_after, p_parent_roll_id, v_result = 'C', p_label)
  RETURNING id INTO v_id;
  IF p_parent_roll_id IS NOT NULL THEN
    UPDATE public.rpg_rolls SET extra_pending = false WHERE id = p_parent_roll_id;
  END IF;

  RETURN jsonb_build_object('roll_id', v_id, 'character_id', p_character_id, 'stat_key', p_stat_key, 'stat_name', v_stat->>'name',
    'skill', v_skill, 'difficulty', v_diff, 'needed', v_nc->'needed', 'critical', v_nc->'critical',
    'roll', v_roll, 'result', v_result, 'points', round(v_points, 1), 'level_before', v_before, 'level_after', v_after,
    'extra_pending', v_result = 'C', 'parent_roll_id', p_parent_roll_id, 'label', p_label, 'created_at', now());
END;
$$;

-- The additional roll a critical prompts. Same character, stat and difficulty; it can be a critical too and chain.
CREATE OR REPLACE FUNCTION public.rpg_roll_extra(p_parent_roll_id uuid)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_p record;
BEGIN
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_p FROM public.rpg_rolls WHERE id = p_parent_roll_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'roll not found'; END IF;
  IF NOT v_p.extra_pending THEN RAISE EXCEPTION 'that roll has no additional roll waiting'; END IF;
  RETURN public.rpg_roll(v_p.character_id, v_p.stat_key, v_p.difficulty, v_p.label, p_parent_roll_id, v_p.session_id);
END;
$$;

-- Recent rolls for one character, newest first, for the sheet's roll log.
CREATE OR REPLACE FUNCTION public.rpg_recent_rolls(p_character_id uuid, p_limit integer DEFAULT 20)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('roll_id', r.id, 'stat_key', r.stat_key, 'stat_name', d.name, 'skill', r.skill,
           'difficulty', r.difficulty, 'needed', r.needed, 'critical', r.critical_at, 'roll', r.roll, 'result', r.result,
           'points', round(r.points_awarded, 1), 'level_before', r.level_before, 'level_after', r.level_after,
           'extra_pending', r.extra_pending, 'parent_roll_id', r.parent_roll_id, 'label', r.label, 'created_at', r.created_at)
           ORDER BY r.created_at DESC), '[]'::jsonb)
  FROM (SELECT * FROM public.rpg_rolls WHERE character_id = p_character_id AND (SELECT public.rpg_can_play())
        ORDER BY created_at DESC LIMIT greatest(coalesce(p_limit, 20), 1)) r
  LEFT JOIN public.rpg_stat_definitions d ON d.key = r.stat_key AND d.agency_id = r.agency_id;
$$;

-- Character list for the Characters tab.
CREATE OR REPLACE FUNCTION public.rpg_character_list()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'kid_id', c.kid_id, 'kid_name', k.name,
           'is_npc', c.is_npc, 'color', c.color, 'vitality_damage', c.vitality_damage, 'is_active', c.is_active,
           'created_at', c.created_at) ORDER BY c.is_npc, k.sort_order NULLS LAST, c.created_at), '[]'::jsonb)
  FROM public.rpg_characters c
  LEFT JOIN public.family_kids k ON k.id = c.kid_id
  WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND (SELECT public.rpg_can_play());
$$;

GRANT EXECUTE ON FUNCTION public.rpg_can_play(), public.rpg_setting(text), public.rpg_needed(numeric, numeric),
  public.rpg_level_cost(integer), public.rpg_formula_text(jsonb, jsonb), public.rpg_roll_inputs(),
  public.rpg_sheet(uuid, numeric), public.rpg_new_character(text, uuid, boolean), public.rpg_reroll_character(uuid),
  public.rpg_set_input(uuid, text, integer), public.rpg_adjust_vitality(uuid, integer),
  public.rpg_roll(uuid, text, numeric, text, uuid, uuid), public.rpg_roll_extra(uuid),
  public.rpg_recent_rolls(uuid, integer), public.rpg_character_list() TO authenticated;
