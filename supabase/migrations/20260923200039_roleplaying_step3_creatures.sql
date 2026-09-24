-- Roleplaying module, step 3 of the build plan (persistent_memory spec
-- "Roleplaying module — build plan + state", project roleplaying): creature cards.
-- Source: the Bramblemaw card, admin manual > Outside Agency > Roleplaying
-- (manuals id 9be683d5-4a8c-40f1-8364-d03d09074268). Card text below is verbatim.
-- Card numbers are stored as printed. Peter's ruling creature_conversion (rpg_rules)
-- turns them into d100 numbers at the table: the to-hit bonus is the attack skill,
-- armor class minus 10 is the difficulty to hit it, a save DC minus 10 is that save's
-- difficulty, hit points stay as printed, and creatures roll against the character's
-- Evade Enemy. The 10 lives in rpg_settings (card_difficulty_offset).
-- Who sees what: parents (the game master) see the whole card. The Family Hub login sees
-- a creature only after a parent marks it shown, and then only its names, haunts and lore.
-- Stats, actions, the rumor table and the tip stay with the game master, so both tables
-- are parent-only and players read through rpg_creature_list() / rpg_creature_card().
-- Nothing destructive: two new tables, one new setting, three new functions, one creature.

-- ───────────────────────── tables ─────────────────────────
CREATE TABLE IF NOT EXISTS public.rpg_creatures (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id              uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365',
  key                    text NOT NULL,
  name                   text NOT NULL,                 -- common name, what the list shows
  card_title             text,                          -- the stat block heading
  scholarly_name         text,
  whispered_label        text,                          -- the card's own words above the name list
  whispered_names        text[] NOT NULL DEFAULT '{}',
  haunts                 text,
  epigraph               text,
  lore                   text,                          -- markdown, verbatim from the card
  size                   text NOT NULL CHECK (size IN ('Tiny','Small','Medium','Large','Huge','Gargantuan')),
  creature_type          text NOT NULL,
  alignment              text,
  challenge              text,
  xp                     integer CHECK (xp >= 0),
  armor_class            integer NOT NULL CHECK (armor_class >= 0),
  armor_note             text,
  hit_points             integer NOT NULL CHECK (hit_points > 0),
  hit_dice               text,
  speed_ft               integer NOT NULL DEFAULT 30 CHECK (speed_ft >= 0),
  burrow_ft              integer CHECK (burrow_ft >= 0),
  climb_ft               integer CHECK (climb_ft >= 0),
  fly_ft                 integer CHECK (fly_ft >= 0),
  swim_ft                integer CHECK (swim_ft >= 0),
  str_score              integer NOT NULL CHECK (str_score BETWEEN 1 AND 30),
  dex_score              integer NOT NULL CHECK (dex_score BETWEEN 1 AND 30),
  con_score              integer NOT NULL CHECK (con_score BETWEEN 1 AND 30),
  int_score              integer NOT NULL CHECK (int_score BETWEEN 1 AND 30),
  wis_score              integer NOT NULL CHECK (wis_score BETWEEN 1 AND 30),
  cha_score              integer NOT NULL CHECK (cha_score BETWEEN 1 AND 30),
  saving_throws          jsonb NOT NULL DEFAULT '[]'::jsonb,   -- [{"ability":"str","bonus":10}] in card order
  skills                 jsonb NOT NULL DEFAULT '[]'::jsonb,   -- [{"name":"Perception","bonus":6}] in card order
  damage_vulnerabilities text,
  damage_resistances     text,
  damage_immunities      text,
  condition_immunities   text,
  senses                 text,
  languages              text,
  legendary_per_round    integer NOT NULL DEFAULT 0 CHECK (legendary_per_round >= 0),
  legendary_intro        text,
  lair_title             text,
  lair_intro             text,
  rumor_title            text,
  rumor_intro            text,
  rumors                 jsonb NOT NULL DEFAULT '[]'::jsonb,   -- [{"roll":1,"text":"…","truth":"interpretation|partial|true|false"}]
  rumor_note             text,
  gm_tip                 text,
  color                  text NOT NULL DEFAULT '#6B2E2A',
  source_manual_id       uuid REFERENCES public.manuals(id) ON DELETE SET NULL,
  shown_to_players       boolean NOT NULL DEFAULT false,
  is_active              boolean NOT NULL DEFAULT true,
  sort_order             integer NOT NULL DEFAULT 0,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, key)
);

CREATE TABLE IF NOT EXISTS public.rpg_creature_actions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id       uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365',
  creature_id     uuid NOT NULL REFERENCES public.rpg_creatures(id) ON DELETE CASCADE,
  kind            text NOT NULL CHECK (kind IN ('trait','action','bonus_action','reaction','legendary','lair')),
  name            text NOT NULL,
  description     text NOT NULL,                  -- markdown, verbatim from the card
  to_hit          integer,                        -- attack bonus as printed = the d100 attack skill
  reach_ft        integer CHECK (reach_ft >= 0),
  range_text      text,
  save_dc         integer,                        -- as printed; minus card_difficulty_offset = save difficulty
  save_ability    text CHECK (save_ability IN ('str','dex','con','int','wis','cha')),
  recharge_min    integer CHECK (recharge_min BETWEEN 2 AND 6),  -- 5 = "Recharge 5–6"
  legendary_cost  integer NOT NULL DEFAULT 1 CHECK (legendary_cost >= 1),
  makes_attacks   jsonb,                          -- the attacks this action makes: [{"action":"Claw","count":2}]
  sort_order      integer NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (creature_id, kind, name)
);

CREATE OR REPLACE TRIGGER rpg_creatures_set_updated_at BEFORE UPDATE ON public.rpg_creatures
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.rpg_creatures        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rpg_creature_actions ENABLE ROW LEVEL SECURITY;
CREATE POLICY rpg_creatures_parents_all ON public.rpg_creatures FOR ALL TO authenticated USING (agency_id = '126794dd-25ff-47d2-a436-724499733365' AND (SELECT public.family_is_parent())) WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365' AND (SELECT public.family_is_parent()));
CREATE POLICY rpg_creature_actions_parents_all ON public.rpg_creature_actions FOR ALL TO authenticated USING (agency_id = '126794dd-25ff-47d2-a436-724499733365' AND (SELECT public.family_is_parent())) WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365' AND (SELECT public.family_is_parent()));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.rpg_creatures, public.rpg_creature_actions TO authenticated;

-- ───────────────────────── settings ─────────────────────────
INSERT INTO public.rpg_settings (key, value, label) VALUES
  ('card_difficulty_offset', 10, 'Creature cards: armor class and save DC minus this = the d100 difficulty')
ON CONFLICT (agency_id, key) DO NOTHING;

-- ───────────────────────── functions ─────────────────────────
-- A card's armor class or save DC as a d100 difficulty (ruling creature_conversion).
CREATE OR REPLACE FUNCTION public.rpg_card_difficulty(p_card_value numeric)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT p_card_value - public.rpg_setting('card_difficulty_offset');
$function$;

-- The Creatures tab list. Players get only shown creatures and only safe fields.
CREATE OR REPLACE FUNCTION public.rpg_creature_list()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH gm AS (SELECT public.family_is_parent() AS is_gm)
  SELECT coalesce(jsonb_agg(
           jsonb_build_object('id', c.id, 'key', c.key, 'name', c.name, 'color', c.color, 'epigraph', c.epigraph)
           || CASE WHEN gm.is_gm THEN jsonb_build_object('challenge', c.challenge, 'armor_class', c.armor_class,
                'hit_points', c.hit_points, 'shown_to_players', c.shown_to_players) ELSE '{}'::jsonb END
           ORDER BY c.sort_order, c.name), '[]'::jsonb)
  FROM public.rpg_creatures c CROSS JOIN gm
  WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active
    AND (SELECT public.rpg_can_play()) AND (gm.is_gm OR c.shown_to_players);
$function$;

-- One creature card. Players: names, haunts and lore of a shown creature. Parents: everything,
-- the stat block lines built from the stored numbers, and the d100 numbers the ruling gives.
CREATE OR REPLACE FUNCTION public.rpg_creature_card(p_creature_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_gm   boolean := public.family_is_parent();
  v_c    public.rpg_creatures%ROWTYPE;
  v_card jsonb;
BEGIN
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_c FROM public.rpg_creatures
   WHERE id = p_creature_id AND agency_id = '126794dd-25ff-47d2-a436-724499733365' AND is_active;
  IF NOT FOUND OR NOT (v_gm OR v_c.shown_to_players) THEN RETURN NULL; END IF;

  v_card := jsonb_build_object(
    'id', v_c.id, 'key', v_c.key, 'name', v_c.name, 'color', v_c.color, 'is_gm', v_gm,
    'scholarly_name', v_c.scholarly_name, 'whispered_label', v_c.whispered_label,
    'whispered_names', to_jsonb(v_c.whispered_names), 'haunts', v_c.haunts,
    'epigraph', v_c.epigraph, 'lore', v_c.lore);
  IF NOT v_gm THEN RETURN v_card; END IF;

  RETURN v_card || jsonb_build_object(
    'shown_to_players', v_c.shown_to_players,
    'source_manual_id', v_c.source_manual_id,
    'card_title', v_c.card_title,
    'type_line', v_c.size || ' ' || v_c.creature_type || coalesce(', ' || v_c.alignment, ''),
    'armor_text', v_c.armor_class || coalesce(' (' || v_c.armor_note || ')', ''),
    'hit_points_text', v_c.hit_points || coalesce(' (' || v_c.hit_dice || ')', ''),
    'speed_text', v_c.speed_ft || ' ft.'
        || coalesce(', burrow ' || v_c.burrow_ft || ' ft.', '') || coalesce(', climb ' || v_c.climb_ft || ' ft.', '')
        || coalesce(', fly ' || v_c.fly_ft || ' ft.', '') || coalesce(', swim ' || v_c.swim_ft || ' ft.', ''),
    'abilities', jsonb_build_array(
        jsonb_build_object('key', 'str', 'label', 'STR', 'score', v_c.str_score, 'mod', floor((v_c.str_score - 10) / 2.0)::int),
        jsonb_build_object('key', 'dex', 'label', 'DEX', 'score', v_c.dex_score, 'mod', floor((v_c.dex_score - 10) / 2.0)::int),
        jsonb_build_object('key', 'con', 'label', 'CON', 'score', v_c.con_score, 'mod', floor((v_c.con_score - 10) / 2.0)::int),
        jsonb_build_object('key', 'int', 'label', 'INT', 'score', v_c.int_score, 'mod', floor((v_c.int_score - 10) / 2.0)::int),
        jsonb_build_object('key', 'wis', 'label', 'WIS', 'score', v_c.wis_score, 'mod', floor((v_c.wis_score - 10) / 2.0)::int),
        jsonb_build_object('key', 'cha', 'label', 'CHA', 'score', v_c.cha_score, 'mod', floor((v_c.cha_score - 10) / 2.0)::int)),
    'saving_throws_text', (SELECT string_agg(initcap(e->>'ability') || ' ' || CASE WHEN (e->>'bonus')::int < 0 THEN '−' ELSE '+' END
                             || abs((e->>'bonus')::int), ', ' ORDER BY o) FROM jsonb_array_elements(v_c.saving_throws) WITH ORDINALITY AS t(e, o)),
    'skills_text', (SELECT string_agg((e->>'name') || ' ' || CASE WHEN (e->>'bonus')::int < 0 THEN '−' ELSE '+' END
                      || abs((e->>'bonus')::int), ', ' ORDER BY o) FROM jsonb_array_elements(v_c.skills) WITH ORDINALITY AS t(e, o)),
    'damage_vulnerabilities', v_c.damage_vulnerabilities,
    'damage_resistances', v_c.damage_resistances,
    'damage_immunities', v_c.damage_immunities,
    'condition_immunities', v_c.condition_immunities,
    'senses', v_c.senses,
    'languages', v_c.languages,
    'challenge_text', v_c.challenge || coalesce(' (' || to_char(v_c.xp, 'FM999,999,990') || ' XP)', ''),
    'legendary_per_round', v_c.legendary_per_round,
    'legendary_intro', v_c.legendary_intro,
    'lair_title', v_c.lair_title,
    'lair_intro', v_c.lair_intro,
    'rumor_title', v_c.rumor_title,
    'rumor_intro', v_c.rumor_intro,
    'rumors', v_c.rumors,
    'rumor_note', v_c.rumor_note,
    'gm_tip', v_c.gm_tip,
    'table', jsonb_build_object(
        'difficulty_to_hit', public.rpg_card_difficulty(v_c.armor_class),
        'hit_points', v_c.hit_points,
        'attacks_roll_against', (SELECT d.name FROM public.rpg_stat_definitions d
                                  WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND d.key = 'EE')),
    'actions', (SELECT coalesce(jsonb_agg(jsonb_build_object(
        'id', a.id, 'kind', a.kind, 'name', a.name,
        'heading', a.name
            || CASE WHEN a.recharge_min IS NULL THEN '' WHEN a.recharge_min < 6 THEN ' (Recharge ' || a.recharge_min || '–6)' ELSE ' (Recharge 6)' END
            || CASE WHEN a.kind = 'legendary' AND a.legendary_cost > 1 THEN ' (Costs ' || a.legendary_cost || ' Actions)' ELSE '' END,
        'description', a.description,
        'to_hit', a.to_hit, 'reach_ft', a.reach_ft, 'range_text', a.range_text,
        'save_dc', a.save_dc, 'save_ability', a.save_ability,
        'save_ability_name', CASE a.save_ability WHEN 'str' THEN 'Strength' WHEN 'dex' THEN 'Dexterity' WHEN 'con' THEN 'Constitution'
                               WHEN 'int' THEN 'Intelligence' WHEN 'wis' THEN 'Wisdom' WHEN 'cha' THEN 'Charisma' END,
        'save_difficulty', public.rpg_card_difficulty(a.save_dc),
        'recharge_min', a.recharge_min, 'legendary_cost', a.legendary_cost, 'makes_attacks', a.makes_attacks)
      ORDER BY array_position(ARRAY['trait','action','bonus_action','reaction','legendary','lair'], a.kind), a.sort_order), '[]'::jsonb)
      FROM public.rpg_creature_actions a WHERE a.creature_id = v_c.id));
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpg_card_difficulty(numeric), public.rpg_creature_list(), public.rpg_creature_card(uuid) TO authenticated;

-- ───────────────────────── Bramblemaw, from the card ─────────────────────────
WITH c AS (
  INSERT INTO public.rpg_creatures (key, name, card_title, scholarly_name, whispered_label, whispered_names, haunts, epigraph, lore,
    size, creature_type, alignment, challenge, xp, armor_class, armor_note, hit_points, hit_dice, speed_ft, climb_ft,
    str_score, dex_score, con_score, int_score, wis_score, cha_score, saving_throws, skills,
    damage_resistances, condition_immunities, senses, languages,
    legendary_per_round, legendary_intro, lair_title, lair_intro,
    rumor_title, rumor_intro, rumors, rumor_note, gm_tip, source_manual_id, sort_order)
  VALUES ('bramblemaw', 'Bramblemaw', 'Bramblemaw, Thornbound Devourer', 'Dentivora silvae maledicta',
    'Names peasants whisper, unsure if it’s even real',
    ARRAY['The Hunger Beneath the Roots', 'The Thing in the Briars', 'The Red-Eyed One', 'The Forest That Walks'],
    'Old-growth forests, cursed roads, abandoned borderlands',
    'Where the roots twist too tightly and the birds fall silent, the Bramblemaw walks.',
    E'The Bramblemaw is a forest-born terror said to arise when ancient woods are steeped too long in blood, oath-breaking, or forgotten wars. Neither beast nor demon, it resembles a towering, spike-backed horror with a skull-like face and burning eyes, as if the forest itself learned hunger.\n\nIt does not hunt for sustenance alone. Witnesses claim the Bramblemaw stalks travelers who stray from worn paths or linger too long beneath dead branches, testing them first with silence before revealing itself. Its claws tear bark as easily as mail, and its bite leaves wounds that rot even when survived.\n\nOld wardens insist the creature cannot be truly slain—only driven off. They claim it returns to the soil when wounded, sleeping for years beneath tangled roots until the forest “needs it” again.',
    'Huge', 'monstrosity (legendary)', 'chaotic neutral', '10', 5900, 16, 'natural armor', 189, '18d12 + 72', 40, 30,
    22, 14, 18, 6, 14, 10,
    '[{"ability":"str","bonus":10},{"ability":"con","bonus":8},{"ability":"wis","bonus":6}]'::jsonb,
    '[{"name":"Perception","bonus":6},{"name":"Stealth","bonus":6},{"name":"Survival","bonus":6}]'::jsonb,
    'Bludgeoning, piercing, and slashing from nonmagical attacks',
    'Frightened',
    'Darkvision 120 ft., tremorsense 30 ft., passive Perception 16',
    'Understands Sylvan and Common but cannot speak',
    3, 'The Bramblemaw can take 3 legendary actions, choosing from the options below. Only one legendary action may be used at a time, and only at the end of another creature’s turn.',
    'Forest Domain', 'On initiative count 20 (losing initiative ties), the Bramblemaw can take one lair action while in its forest lair:',
    'Whispers of the Bramblemaw', 'When characters ask around villages, taverns, rangers, or road-wardens, roll 1d6.',
    jsonb_build_array(
      jsonb_build_object('roll', 1, 'truth', 'interpretation', 'text', '“The forest moves at night. Trees shift. Paths vanish. That’s when it’s hunting.”'),
      jsonb_build_object('roll', 2, 'truth', 'partial',        'text', '“Steel slows it, but fire makes it angry. Burn the woods and it’ll come for you first.”'),
      jsonb_build_object('roll', 3, 'truth', 'interpretation', 'text', '“It doesn’t kill everyone. Some it just watches… like it’s judging them.”'),
      jsonb_build_object('roll', 4, 'truth', 'partial',        'text', '“They say it sleeps beneath roots thicker than towers. Hurt it bad enough, and it sinks back into the earth.”'),
      jsonb_build_object('roll', 5, 'truth', 'interpretation', 'text', '“Animals won’t go near its ground. Not wolves, not birds. If it’s quiet, you’re already too close.”'),
      jsonb_build_object('roll', 6, 'truth', 'interpretation', 'text', '“Old wardens swear it was *made*, not born. A punishment that forgot who it was meant for.”')),
    '(Rumors 2 and 4 are partially true. The rest are interpretations.)',
    'The Bramblemaw should feel less like a boss monster and more like **the forest itself deciding the party is a problem**.',
    '9be683d5-4a8c-40f1-8364-d03d09074268', 10)
  ON CONFLICT (agency_id, key) DO NOTHING
  RETURNING id
)
INSERT INTO public.rpg_creature_actions (creature_id, kind, name, description, to_hit, reach_ft, save_dc, save_ability, recharge_min, legendary_cost, makes_attacks, sort_order)
SELECT c.id, v.kind, v.name, v.description, v.to_hit, v.reach_ft, v.save_dc, v.save_ability, v.recharge_min, v.legendary_cost, v.makes_attacks, v.sort_order
FROM c CROSS JOIN (VALUES
  ('trait', 'Forest-Bound Terror', 'While in forested terrain, the Bramblemaw has advantage on Stealth checks, and difficult terrain caused by plants does not slow it.',
     NULL::integer, NULL::integer, NULL::integer, NULL::text, NULL::integer, 1, NULL::jsonb, 10),
  ('trait', 'Rooted Resilience', 'When reduced to 0 hit points while in a forest, the Bramblemaw does not die immediately. Instead, it sinks into the ground, becoming inert. Unless its body is burned or sanctified within 1 minute, it regains 1 hit point and escapes underground after 1 hour.',
     NULL, NULL, NULL, NULL, NULL, 1, NULL, 20),
  ('trait', 'Judging Gaze', E'As a bonus action, the Bramblemaw fixes its glowing eyes on one creature it can see within 60 feet. Until the end of the Bramblemaw’s next turn:\n\n- That creature has disadvantage on its next saving throw.\n- If the creature attacks a tree, animal, or innocent NPC during this time, the Bramblemaw gains advantage on all attacks against it for 1 minute.',
     NULL, NULL, NULL, NULL, NULL, 1, NULL, 30),
  ('action', 'Multiattack', 'The Bramblemaw makes **two Claw attacks** and **one Bite attack**.',
     NULL, NULL, NULL, NULL, NULL, 1, '[{"action":"Claw","count":2},{"action":"Bite","count":1}]'::jsonb, 10),
  ('action', 'Claw', E'*Melee Weapon Attack:* +10 to hit, reach 10 ft., one target  \n*Hit:* 17 (2d10 + 6) slashing damage.  \nIf the target is Large or smaller, it must succeed on a DC 18 Strength saving throw or be knocked prone.',
     10, 10, 18, 'str', NULL, 1, NULL, 20),
  ('action', 'Bite', E'*Melee Weapon Attack:* +10 to hit, reach 5 ft., one target  \n*Hit:* 22 (2d12 + 6) piercing damage plus 7 (2d6) necrotic damage.  \nIf the target is restrained or prone, the bite deals an extra 10 (3d6) necrotic damage.',
     10, 5, NULL, NULL, NULL, 1, NULL, 30),
  ('action', 'Briar Roar', E'The Bramblemaw unleashes a thunderous roar. Each creature of its choice within 30 feet must make a DC 16 Wisdom saving throw or be **frightened** for 1 minute.  \nA frightened creature can repeat the save at the end of each of its turns, ending the effect on a success.',
     NULL, NULL, 16, 'wis', 5, 1, NULL, 40),
  ('legendary', 'Rootstep', 'The Bramblemaw moves up to half its speed without provoking opportunity attacks.',
     NULL, NULL, NULL, NULL, NULL, 1, NULL, 10),
  ('legendary', 'Rending Swipe', 'The Bramblemaw makes one Claw attack.',
     NULL, NULL, NULL, NULL, NULL, 1, '[{"action":"Claw","count":1}]'::jsonb, 20),
  ('legendary', 'Sink Into Soil', 'The Bramblemaw partially submerges into the ground, gaining half cover until the start of its next turn.',
     NULL, NULL, NULL, NULL, NULL, 2, NULL, 30),
  ('lair', 'Grasping Roots', 'Vines and roots erupt in a 20-foot square the Bramblemaw can see. Creatures in the area must succeed on a DC 15 Strength save or be restrained until the next round.',
     NULL, NULL, 15, 'str', NULL, 1, NULL, 10),
  ('lair', 'Living Silence', 'All sound within 60 feet is muffled until the next round. Wisdom (Perception) checks relying on hearing automatically fail.',
     NULL, NULL, NULL, NULL, NULL, 1, NULL, 20),
  ('lair', 'Briar Shift', 'The terrain subtly rearranges. Nonmagical difficult terrain appears in a 30-foot radius chosen by the Bramblemaw.',
     NULL, NULL, NULL, NULL, NULL, 1, NULL, 30)
) AS v(kind, name, description, to_hit, reach_ft, save_dc, save_ability, recharge_min, legendary_cost, makes_attacks, sort_order);
