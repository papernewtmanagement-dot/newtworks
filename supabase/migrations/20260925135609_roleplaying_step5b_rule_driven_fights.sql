-- Roleplaying step 5b: rule-driven fights (Peter 2026-09-25).
-- No picking who acts: the one whose turn it is acts. Effects come from creature cards and run themselves: an action
-- that lands puts an effect on its target (Held, Knocked down, Frightened) and the rules clear it: at the start of
-- the target's turn, at the next round, or by a check the target rolls before attacking. Players may enter a die
-- they rolled by hand. The log leads with the outcome (Big hit for 28 / Miss / Success). Creatures get an automatic
-- turn. Rule cards get sections. Creatures get a picture slot and four new cards.

ALTER TABLE public.rpg_rules ADD COLUMN IF NOT EXISTS section text;
ALTER TABLE public.rpg_creature_actions ADD COLUMN IF NOT EXISTS effect jsonb;
COMMENT ON COLUMN public.rpg_creature_actions.effect IS 'What a landed action does to its target: {"on": "hit" | "land", "contest": {"skill_key": "strength", "against": "ST"}, "apply": {"name": "Knocked down", "cannot_act": true, "clear": "turn_start" | "round" | "check", "check_stat": "CO", "check_difficulty": 8, "on_fail": "no_attack"}}';
ALTER TABLE public.rpg_session_participants ADD COLUMN IF NOT EXISTS effects jsonb NOT NULL DEFAULT '[]'::jsonb;
COMMENT ON COLUMN public.rpg_session_participants.effects IS 'Effects on this participant now, each the apply object from the action plus source, round and checked_round.';
ALTER TABLE public.rpg_events ADD COLUMN IF NOT EXISTS outcome text;
ALTER TABLE public.rpg_rolls ADD COLUMN IF NOT EXISTS manual boolean NOT NULL DEFAULT false;
ALTER TABLE public.rpg_creatures ADD COLUMN IF NOT EXISTS image_path text;

-- Rule cards: sections, and an order that keeps each section together.
UPDATE public.rpg_rules SET section = CASE key
  WHEN 'roll_check' THEN 'Rolling' WHEN 'critical_rolls' THEN 'Rolling' WHEN 'damage' THEN 'Rolling' WHEN 'log_outcomes' THEN 'Rolling'
  WHEN 'turn_order' THEN 'Fights' WHEN 'creature_conversion' THEN 'Fights'
  WHEN 'skill_gain' THEN 'Getting Better' WHEN 'tutors' THEN 'Getting Better'
  WHEN 'rolling_pc' THEN 'Characters' WHEN 'strength_roll' THEN 'Characters' WHEN 'npcs' THEN 'Characters'
  WHEN 'currency' THEN 'Money' ELSE coalesce(section, 'Rules') END,
  sort_order = CASE key WHEN 'roll_check' THEN 10 WHEN 'critical_rolls' THEN 20 WHEN 'damage' THEN 30 WHEN 'log_outcomes' THEN 35
    WHEN 'turn_order' THEN 40 WHEN 'creature_conversion' THEN 50 WHEN 'skill_gain' THEN 60 WHEN 'tutors' THEN 70
    WHEN 'rolling_pc' THEN 80 WHEN 'strength_roll' THEN 90 WHEN 'npcs' THEN 100 WHEN 'currency' THEN 110 ELSE sort_order END;
UPDATE public.rpg_rules
   SET body = replace(body, ' The game master can move anyone up or down the line.', '')
     || E'\n\nBefore you attack, shake off what is on you. Frightened by Briar Roar: roll Courage against 8 (Courage 7 needs 54 or more). Pass and it is gone; fail and you cannot attack this turn. Held by Grasping Roots ends when the next round starts. Knocked down by a Claw ends when your turn starts: you get up and act.'
 WHERE key = 'turn_order' AND body NOT LIKE '%shake off what is on you%';
INSERT INTO public.rpg_rules (key, title, body, source, sort_order, section)
SELECT 'log_outcomes', 'What the Log Says', 'Every roll in the log leads with its outcome. Miss: the die is under Needed. Wild miss: 30 or more under. Weak hit: 1 to 5 damage. Solid hit: 6 to 20. Big hit: 21 or more. Critical hit: the die is at or above the critical mark, and the extra roll adds on. A check says Success or Fail. Needed 50: a 12 is a Wild miss, a 48 a Miss, a 53 a Weak hit for 3, a 70 a Solid hit for 20, an 80 a Big hit for 30, a 96 a Critical hit.', 'engine', 35, 'Rolling'
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_rules WHERE key = 'log_outcomes');

-- Bramblemaw's effects, from its card notes.
UPDATE public.rpg_creature_actions SET effect = '{"on": "hit", "contest": {"skill_key": "strength", "against": "ST"}, "apply": {"name": "Knocked down", "cannot_act": true, "clear": "turn_start"}}'::jsonb WHERE id = 'b0d44b36-f883-4776-bea2-175d85e3de5e';
UPDATE public.rpg_creature_actions SET effect = '{"on": "land", "apply": {"name": "Held", "cannot_act": true, "clear": "round"}}'::jsonb WHERE id = '89e0bc67-161f-4568-afb4-5dc51a3aab8d';
UPDATE public.rpg_creature_actions SET effect = '{"on": "land", "apply": {"name": "Frightened", "cannot_act": false, "clear": "check", "check_stat": "CO", "check_difficulty": 8, "on_fail": "no_attack"}}'::jsonb WHERE id = '2d099318-eaa5-443e-ab54-1c782357c5cf';

-- Four new creatures on the character scale, hidden from players until a parent shows them. The d20 numbers are
-- reading and flavor only, like Bramblemaw's.
INSERT INTO public.rpg_creatures (agency_id, key, name, size, creature_type, color, lore, gm_tip, armor_class, str_score, dex_score, con_score, int_score, wis_score, cha_score,
                                  attack_skill, defense_skill, strength_skill, will_skill, stealth_skill, awareness_skill, agility_skill, vitality, hit_points, legendary_per_round, shown_to_players, is_active, sort_order)
SELECT '126794dd-25ff-47d2-a436-724499733365', v.key, v.name, v.size, v.ctype, v.color, v.lore, v.tip, v.ac, v.s1, v.s2, v.s3, v.s4, v.s5, v.s6,
       v.att, v.def, v.str, v.wil, v.ste, v.awa, v.agi, v.vit, v.vit, 0, false, true, v.so
  FROM (VALUES
    ('ashwing_harrier', 'Ashwing Harrier', 'Large', 'beast', '#8A5A2B', 'A hawk the size of a pony that hunts the burnt hills. It circles high, screams once, and dives. Charcoal feathers, eyes like coals, and talons that have never let go of anything.', 'Fast and fragile. It picks one target, screeches to scatter the others, and dives. Kill it quick or it wears you down.', 14, 12, 18, 12, 4, 16, 8, 7, 9, 6, 6, 6, 10, 9, 45, 20),
    ('mossback_elder', 'Mossback Elder', 'Huge', 'beast', '#4F6B3A', 'An ancient tortoise with a hill of moss for a shell. Trees grow on its back. Slow to anger, impossible to move, and it remembers every fire ever lit in its valley.', 'A wall that hits back. It cannot chase anyone, so the fight is on the players'' terms unless they stand still.', 20, 22, 4, 20, 6, 14, 8, 8, 11, 12, 9, 3, 5, 2, 220, 30),
    ('gloam_wisp', 'Gloam Wisp', 'Tiny', 'fey', '#5E7FB0', 'A cold light that drifts through fog and calls your name in a voice you almost know. Those who follow it come back years later, or not at all.', 'Weak in a straight fight. Its whole game is Lure: an entranced player walks toward it while the others argue about what they see.', 15, 3, 16, 10, 12, 15, 19, 5, 10, 2, 11, 10, 8, 8, 30, 40),
    ('thornfield_boar', 'Thornfield Boar', 'Medium', 'beast', '#7A4A2E', 'A boar armored in thorns that charges anything moving in the Thornfields. Its tusks are old iron, and its temper is older.', 'Simple and mean: a charge to knock someone flat, then Gore. Good first fight for a new character.', 13, 18, 12, 16, 3, 12, 6, 8, 7, 10, 7, 4, 7, 7, 70, 50)
  ) v(key, name, size, ctype, color, lore, tip, ac, s1, s2, s3, s4, s5, s6, att, def, str, wil, ste, awa, agi, vit, so)
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_creatures c WHERE c.key = v.key);
INSERT INTO public.rpg_creature_actions (agency_id, creature_id, kind, name, description, skill, against, deals_damage, recharge_min, legendary_cost, sort_order, table_note, effect)
SELECT '126794dd-25ff-47d2-a436-724499733365', c.id, v.kind, v.name, v.descr, v.skill, v.vs, v.dmg, v.rc, 1, v.so, v.note, v.fx::jsonb
  FROM (VALUES
    ('ashwing_harrier', 'action', 'Talon Dive', 'The harrier folds its wings and drops on one target.', 7, 'EE', true, NULL::integer, 10, 'Rolls 7 against the target''s Evade Enemy × 2 (Evade Enemy 5 → difficulty 10 → needs 59 or more).', NULL::text),
    ('ashwing_harrier', 'action', 'Hunting Screech', 'A scream that scatters prey. Recharges on a 5 or 6.', 6, 'CO', false, 5, 20, 'Rolls 6 against each target''s Courage × 2 (Courage 7 → difficulty 14 → needs 70 or more). Those it beats are frightened: on their turn they may roll Courage against 6 to shake it off (Courage 7 needs 47 or more).', '{"on": "land", "apply": {"name": "Frightened", "cannot_act": false, "clear": "check", "check_stat": "CO", "check_difficulty": 6, "on_fail": "no_attack"}}'),
    ('mossback_elder', 'action', 'Shell Slam', 'The elder rears and comes down shell first.', 8, 'EE', true, NULL, 10, 'Rolls 8 against Evade Enemy × 2 (Evade Enemy 5 → difficulty 10 → needs 56 or more). A hit also rolls its Strength 12 against the target''s Strength × 2; if that lands the target is knocked down until their turn starts.', '{"on": "hit", "contest": {"skill_key": "strength", "against": "ST"}, "apply": {"name": "Knocked down", "cannot_act": true, "clear": "turn_start"}}'),
    ('mossback_elder', 'action', 'Snapping Bite', 'A beak that takes off what it closes on.', 8, 'EE', true, NULL, 20, 'Rolls 8 against Evade Enemy × 2 (Evade Enemy 5 → difficulty 10 → needs 56 or more).', NULL),
    ('gloam_wisp', 'action', 'Lure', 'The wisp speaks in a loved one''s voice.', 9, 'CO', false, NULL, 10, 'Rolls 9 against each target''s Courage × 2 (Courage 7 → difficulty 14 → needs 61 or more). Those it beats are entranced and cannot act; on their turn they may roll Courage against 9 to snap out of it (Courage 7 needs 57 or more).', '{"on": "land", "apply": {"name": "Entranced", "cannot_act": true, "clear": "check", "check_stat": "CO", "check_difficulty": 9, "on_fail": "no_attack"}}'),
    ('gloam_wisp', 'action', 'Cold Touch', 'A brush of light that leaves frost on the skin.', 5, 'EE', true, NULL, 20, 'Rolls 5 against Evade Enemy × 2 (Evade Enemy 5 → difficulty 10 → needs 67 or more).', NULL),
    ('thornfield_boar', 'action', 'Gore', 'Tusks first.', 8, 'EE', true, NULL, 10, 'Rolls 8 against Evade Enemy × 2 (Evade Enemy 5 → difficulty 10 → needs 56 or more).', NULL),
    ('thornfield_boar', 'action', 'Charge', 'The boar lowers its head and runs someone down.', 7, 'AG', false, NULL, 20, 'Rolls 7 against the target''s Agility × 2 (Agility 3 → difficulty 6 → needs 47 or more). Those it beats are knocked down until their turn starts.', '{"on": "land", "apply": {"name": "Knocked down", "cannot_act": true, "clear": "turn_start"}}')
  ) v(ckey, kind, name, descr, skill, vs, dmg, rc, so, note, fx)
  JOIN public.rpg_creatures c ON c.key = v.ckey
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_creature_actions a WHERE a.creature_id = c.id AND a.name = v.name);

-- Pictures live in a private bucket: signed-in family reads, parents upload.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
SELECT 'rpg-images', 'rpg-images', false, 5242880, ARRAY['image/png', 'image/jpeg', 'image/webp']
 WHERE NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'rpg-images');
DROP POLICY IF EXISTS rpg_images_read ON storage.objects;
CREATE POLICY rpg_images_read ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'rpg-images');
DROP POLICY IF EXISTS rpg_images_insert ON storage.objects;
CREATE POLICY rpg_images_insert ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'rpg-images' AND (SELECT public.family_is_parent()));
DROP POLICY IF EXISTS rpg_images_update ON storage.objects;
CREATE POLICY rpg_images_update ON storage.objects FOR UPDATE TO authenticated USING (bucket_id = 'rpg-images' AND (SELECT public.family_is_parent()));
DROP POLICY IF EXISTS rpg_images_delete ON storage.objects;
CREATE POLICY rpg_images_delete ON storage.objects FOR DELETE TO authenticated USING (bucket_id = 'rpg-images' AND (SELECT public.family_is_parent()));

CREATE OR REPLACE FUNCTION public.rpg_participant_can_act(p_participant_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Can this one act right now: the game master's flag, vitality left above 0, and no effect on them that says
-- otherwise (Held, Knocked down, Entranced). Someone who cannot act is hit at skill × 1 instead of × 2.
SELECT p.can_act
   AND (public.rpg_participant_vitality(p.id)->>'left')::integer > 0
   AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p.effects) e WHERE coalesce((e->>'cannot_act')::boolean, false))
  FROM public.rpg_session_participants p WHERE p.id = p_participant_id;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_participant_apply_effect(p_participant_id uuid, p_apply jsonb, p_source text, p_round integer)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Puts an effect on someone (replacing one of the same name): the action's apply object plus where it came from
-- and the round it landed. Knocked down clears at the start of their turn, Held at the next round, Frightened by
-- a check they roll before attacking.
UPDATE public.rpg_session_participants p
   SET effects = (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e WHERE e->>'name' <> p_apply->>'name')
                 || jsonb_build_array(p_apply || jsonb_build_object('source', p_source, 'round', p_round))
 WHERE p.id = p_participant_id;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_outcome(p_roll integer, p_needed numeric, p_critical numeric, p_damage_roll boolean, p_damage integer)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The word the log leads with and its key for color (rule card "What the Log Says"). Attacks: Wild miss (30 or
-- more under Needed), Miss, Weak hit (1 to 5 damage), Solid hit (6 to 20), Big hit (21 or more), Critical hit.
-- Other rolls: Fail, Success, Critical success. Needed 50: 12 Wild miss, 48 Miss, 53 Weak hit, 70 Solid hit, 80 Big hit, 96 Critical hit.
SELECT CASE
  WHEN p_roll < p_needed THEN CASE WHEN NOT p_damage_roll THEN jsonb_build_object('key', 'fail', 'label', 'Fail')
                                   WHEN p_roll <= p_needed - 30 THEN jsonb_build_object('key', 'wild_miss', 'label', 'Wild miss')
                                   ELSE jsonb_build_object('key', 'miss', 'label', 'Miss') END
  WHEN p_roll >= p_critical THEN jsonb_build_object('key', 'critical', 'label', CASE WHEN p_damage_roll THEN 'Critical hit' ELSE 'Critical success' END)
  WHEN NOT p_damage_roll THEN jsonb_build_object('key', 'success', 'label', 'Success')
  WHEN p_damage <= 5 THEN jsonb_build_object('key', 'weak_hit', 'label', 'Weak hit')
  WHEN p_damage <= 20 THEN jsonb_build_object('key', 'hit', 'label', 'Solid hit')
  ELSE jsonb_build_object('key', 'big_hit', 'label', 'Big hit') END;
$function$;

DROP FUNCTION IF EXISTS public.rpg_roll(uuid, text, numeric, text, uuid, uuid, uuid, numeric);
CREATE FUNCTION public.rpg_roll(p_character_id uuid, p_stat_key text, p_difficulty numeric DEFAULT NULL::numeric,
  p_label text DEFAULT NULL::text, p_parent_roll_id uuid DEFAULT NULL::uuid, p_session_id uuid DEFAULT NULL::uuid,
  p_participant_id uuid DEFAULT NULL::uuid, p_skill numeric DEFAULT NULL::numeric, p_roll integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One d100 roll. A character rolls a stat from their sheet and earns skill points on a trainable one, every roll:
-- die × Needed ÷ 100 (Peter 2026-09-24). A creature in a fight (no character; its participant and skill passed in)
-- rolls the skill it is handed, earns nothing, and only the game master rolls it. p_roll is a die rolled by hand
-- (1 to 100) used in place of the random one. Needed comes from rpg_needed; an opponent's difficulty arrives
-- already derived by rpg_difficulty.
DECLARE
  v_sheet jsonb; v_stat jsonb; v_skill numeric; v_diff numeric; v_nc jsonb; v_roll integer; v_result text;
  v_points numeric := 0; v_before integer; v_after integer; v_cost numeric; v_sp numeric; v_earned integer;
  v_id uuid; v_agency uuid; v_name text; v_trainable boolean := false;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  v_diff := coalesce(p_difficulty, public.rpg_setting('default_difficulty'));
  IF v_diff < 0 THEN RAISE EXCEPTION 'difficulty cannot be negative'; END IF;
  IF p_roll IS NOT NULL AND (p_roll < 1 OR p_roll > 100) THEN RAISE EXCEPTION 'a roll is 1 to 100'; END IF;

  IF p_character_id IS NULL THEN
    IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master rolls for a creature'; END IF;
    IF p_participant_id IS NULL OR p_skill IS NULL THEN RAISE EXCEPTION 'a creature roll needs the creature and its skill'; END IF;
    SELECT s.agency_id INTO v_agency
      FROM public.rpg_session_participants p JOIN public.rpg_sessions s ON s.id = p.session_id
     WHERE p.id = p_participant_id AND p.creature_id IS NOT NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'that is not a creature in a fight'; END IF;
    v_skill := greatest(p_skill, 0);
    v_name := p_stat_key;
  ELSE
    v_sheet := public.rpg_sheet(p_character_id, v_diff);
    SELECT s INTO v_stat FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = p_stat_key;
    IF v_stat IS NULL THEN RAISE EXCEPTION 'unknown stat %', p_stat_key; END IF;
    v_skill := (v_stat->>'value')::numeric;
    v_name := v_stat->>'name';
    v_trainable := coalesce((v_stat->>'trainable')::boolean, false);
    SELECT agency_id INTO v_agency FROM public.rpg_characters WHERE id = p_character_id;
  END IF;

  v_nc := public.rpg_needed(v_skill, v_diff);
  v_roll := coalesce(p_roll, floor(random() * 100)::integer + 1);
  v_result := CASE WHEN v_roll >= (v_nc->>'critical')::numeric THEN 'C'
                   WHEN v_roll >= (v_nc->>'needed')::numeric THEN 'Y' ELSE '' END;
  v_before := v_skill::integer; v_after := v_before;

  IF v_trainable THEN
    v_points := v_roll * (v_nc->>'needed')::numeric / 100;
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

  INSERT INTO public.rpg_rolls (agency_id, character_id, participant_id, session_id, stat_key, skill, difficulty, needed,
                                critical_at, roll, result, points_awarded, level_before, level_after, parent_roll_id,
                                extra_pending, label, manual)
  VALUES (v_agency, p_character_id, p_participant_id, p_session_id, p_stat_key, v_skill, v_diff,
          (v_nc->>'needed')::numeric, (v_nc->>'critical')::numeric, v_roll, v_result, v_points, v_before, v_after,
          p_parent_roll_id, v_result = 'C', p_label, p_roll IS NOT NULL)
  RETURNING id INTO v_id;
  IF p_parent_roll_id IS NOT NULL THEN
    UPDATE public.rpg_rolls SET extra_pending = false WHERE id = p_parent_roll_id;
  END IF;

  RETURN jsonb_build_object('roll_id', v_id, 'character_id', p_character_id, 'participant_id', p_participant_id,
    'stat_key', p_stat_key, 'stat_name', v_name, 'skill', v_skill, 'difficulty', v_diff, 'needed', v_nc->'needed',
    'critical', v_nc->'critical', 'roll', v_roll, 'result', v_result, 'points', round(v_points, 1),
    'level_before', v_before, 'level_after', v_after, 'extra_pending', v_result = 'C', 'manual', p_roll IS NOT NULL,
    'parent_roll_id', p_parent_roll_id, 'label', p_label, 'created_at', now());
END;
$function$;

DROP FUNCTION IF EXISTS public.rpg_roll_extra(uuid);
CREATE FUNCTION public.rpg_roll_extra(p_parent_roll_id uuid, p_roll integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The additional roll a critical prompts: same stat, same difficulty, same fight, a creature keeps its skill.
-- p_roll is a die rolled by hand.
DECLARE v_p record;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_p FROM public.rpg_rolls WHERE id = p_parent_roll_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'roll not found'; END IF;
  IF NOT v_p.extra_pending THEN RAISE EXCEPTION 'that roll has no additional roll waiting'; END IF;
  RETURN public.rpg_roll(v_p.character_id, v_p.stat_key, v_p.difficulty, v_p.label, p_parent_roll_id, v_p.session_id,
                         v_p.participant_id, CASE WHEN v_p.character_id IS NULL THEN v_p.skill END, p_roll);
END;
$function$;

DROP FUNCTION IF EXISTS public.rpg_act(uuid, uuid[], text, uuid, text, numeric);
CREATE FUNCTION public.rpg_act(p_actor_id uuid, p_target_ids uuid[] DEFAULT NULL::uuid[], p_stat_key text DEFAULT NULL::text,
  p_action_id uuid DEFAULT NULL::uuid, p_against text DEFAULT NULL::text, p_difficulty numeric DEFAULT NULL::numeric,
  p_roll integer DEFAULT NULL::integer, p_effect text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One move in a fight, by the one whose turn it is. Each target gets its own roll through rpg_roll against a
-- difficulty from rpg_difficulty (the target's stat × 2 when they can act, × 1 when they cannot: held, knocked down,
-- entranced, or down at 0 vitality).
--   A character attacks with a weapon skill against Evade Enemy: Dagger 6 at Bramblemaw (defense 8 → difficulty 16)
--   needs 73; a 90 does 17. One attack per turn (attacks_per_turn). If an effect on them needs a check (Frightened),
--   the attack waits until they roll it: p_effect names it, the check is that effect's stat against its difficulty
--   (Courage against 8, Courage 7 needs 54); pass and it is gone, fail and this turn's attack is lost.
--   A creature uses a card action: the action's skill against its stat (Claw 10 against Evade Enemy); only
--   deals_damage actions hurt. A landed action's effect goes on the target: on "land" outright (Briar Roar →
--   Frightened), on "hit" after a contest roll (Claw hit → Strength 10 against their Strength × 2 → Knocked down).
--   An action that makes one other attack rolls that attack (Rending Swipe → Claw); several are rolled one at a
--   time. Legendary actions spend legendary_left and may be used on other turns, as the card says; a recharge
--   action waits for its six-sided die; an action with no skill is used without a roll. A creature can also roll one
--   of its own skills against a target's stat.
-- p_roll is a die rolled by hand: with it, a critical waits for its extra roll (rpg_act_extra) instead of rolling
-- it here. The log leads with rpg_outcome's word: Big hit for 28, Miss, Success.
DECLARE
  v_gm boolean := public.family_is_parent();
  v_actor record; v_s record; v_act record; v_use record; v_t record;
  v_targets uuid[] := coalesce(p_target_ids, '{}'::uuid[]);
  v_kind text; v_key text; v_label text; v_skill numeric; v_against text; v_against_name text;
  v_damage_ok boolean := false; v_is_attack boolean := false; v_stat_name text;
  v_tid uuid; v_def numeric; v_diff numeric; v_roll jsonb; v_first jsonb; v_extras integer[]; v_i integer;
  v_dmg integer; v_vit jsonb; v_text text; v_needs integer; v_results jsonb := '[]'::jsonb; v_levelup text;
  v_eff jsonb; v_fx jsonb; v_out jsonb; v_pending boolean; v_tail text; v_who text; v_xtext text;
  v_croll jsonb; v_cskill numeric; v_cdiff numeric; v_per integer := public.rpg_setting('attacks_per_turn')::integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_actor FROM public.rpg_session_participants WHERE id = p_actor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_actor.session_id FOR UPDATE;
  IF v_s.status = 'setup' THEN RAISE EXCEPTION 'the fight has not started yet'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  IF v_s.current_participant_id IS DISTINCT FROM p_actor_id THEN
    IF NOT (v_gm AND v_actor.creature_id IS NOT NULL AND p_action_id IS NOT NULL
            AND EXISTS (SELECT 1 FROM public.rpg_creature_actions a WHERE a.id = p_action_id AND a.kind = 'legendary')) THEN
      RAISE EXCEPTION 'it is not %''s turn', v_actor.name;
    END IF;
  END IF;
  IF NOT v_gm AND v_actor.character_id IS NULL THEN RAISE EXCEPTION 'the game master rolls for %', v_actor.name; END IF;
  IF NOT v_actor.can_act THEN RAISE EXCEPTION '% cannot act%', v_actor.name, coalesce(': ' || v_actor.status_note, ''); END IF;
  IF (public.rpg_participant_vitality(p_actor_id)->>'left')::integer <= 0 THEN RAISE EXCEPTION '% is down', v_actor.name; END IF;
  SELECT e->>'name' INTO v_who FROM jsonb_array_elements(v_actor.effects) e WHERE coalesce((e->>'cannot_act')::boolean, false) LIMIT 1;
  IF v_who IS NOT NULL AND p_effect IS DISTINCT FROM v_who THEN RAISE EXCEPTION '% is % and cannot act', v_actor.name, v_who; END IF;
  IF p_actor_id = ANY (v_targets) THEN RAISE EXCEPTION 'choose someone else to aim at'; END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_targets) t(id)
              WHERE NOT EXISTS (SELECT 1 FROM public.rpg_session_participants p WHERE p.id = t.id AND p.session_id = v_s.id)) THEN
    RAISE EXCEPTION 'every target must be in this fight';
  END IF;

  IF p_effect IS NOT NULL THEN
    SELECT e INTO v_eff FROM jsonb_array_elements(v_actor.effects) e WHERE e->>'name' = p_effect AND e->>'clear' = 'check';
    IF v_eff IS NULL THEN RAISE EXCEPTION '% is not % right now', v_actor.name, p_effect; END IF;
    IF v_actor.character_id IS NULL THEN RAISE EXCEPTION 'only characters shake off effects'; END IF;
    IF (v_eff->>'checked_round')::integer = v_s.round THEN RAISE EXCEPTION '% already tried this round', v_actor.name; END IF;
    v_kind := 'check'; v_key := v_eff->>'check_stat'; v_targets := '{}';
    SELECT name INTO v_label FROM public.rpg_stat_definitions WHERE key = v_key;
    v_diff := (v_eff->>'check_difficulty')::numeric;
  ELSIF v_actor.character_id IS NOT NULL THEN
    SELECT name, is_attack INTO v_stat_name, v_is_attack FROM public.rpg_stat_definitions WHERE key = p_stat_key;
    IF NOT FOUND THEN RAISE EXCEPTION 'choose a skill'; END IF;
    v_key := p_stat_key; v_label := v_stat_name;
    IF cardinality(v_targets) > 0 THEN
      IF NOT v_is_attack THEN RAISE EXCEPTION 'choose a weapon skill to attack with'; END IF;
      IF cardinality(v_targets) > 1 THEN RAISE EXCEPTION 'attack one target at a time'; END IF;
      IF v_s.turn_attacks >= v_per THEN RAISE EXCEPTION '% has already attacked this turn', v_actor.name; END IF;
      SELECT e->>'name' INTO v_who FROM jsonb_array_elements(v_actor.effects) e
       WHERE e->>'clear' = 'check' AND (e->>'checked_round')::integer IS DISTINCT FROM v_s.round LIMIT 1;
      IF v_who IS NOT NULL THEN RAISE EXCEPTION '% must shake off % first', v_actor.name, v_who; END IF;
      v_kind := 'attack'; v_against := 'EE'; v_damage_ok := true;
    ELSE
      v_kind := 'check';
      v_diff := greatest(coalesce(p_difficulty, public.rpg_setting('default_difficulty')), 0);
    END IF;
  ELSIF p_action_id IS NOT NULL THEN
    SELECT * INTO v_act FROM public.rpg_creature_actions WHERE id = p_action_id AND creature_id = v_actor.creature_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'that action is not on this creature''s card'; END IF;
    IF v_act.kind = 'trait' THEN RAISE EXCEPTION '% is a trait, not an action', v_act.name; END IF;
    IF jsonb_typeof(v_act.makes_attacks) = 'array' AND jsonb_array_length(v_act.makes_attacks) > 0 THEN
      IF jsonb_array_length(v_act.makes_attacks) > 1 OR coalesce((v_act.makes_attacks->0->>'count')::integer, 1) > 1 THEN
        RAISE EXCEPTION '% is several rolls. Roll them one at a time: %', v_act.name,
          (SELECT string_agg((e->>'count') || ' × ' || (e->>'action'), ', ') FROM jsonb_array_elements(v_act.makes_attacks) e);
      END IF;
      SELECT * INTO v_use FROM public.rpg_creature_actions
       WHERE creature_id = v_actor.creature_id AND name = v_act.makes_attacks->0->>'action' LIMIT 1;
      IF NOT FOUND THEN RAISE EXCEPTION '% names an attack that is not on the card', v_act.name; END IF;
    ELSE
      v_use := v_act;
    END IF;
    IF v_act.kind = 'legendary' AND v_actor.legendary_left < v_act.legendary_cost THEN
      RAISE EXCEPTION '% has % legendary actions left and % costs %', v_actor.name, v_actor.legendary_left, v_act.name, v_act.legendary_cost;
    END IF;
    IF v_act.recharge_min IS NOT NULL AND v_actor.recharge_state ? v_act.id::text THEN
      RAISE EXCEPTION '% is not ready. It comes back on a six-sided die roll of % or more at the start of %''s turn',
        v_act.name, v_act.recharge_min, v_actor.name;
    END IF;
    v_kind := 'action'; v_label := v_act.name; v_key := v_use.name; v_skill := v_use.skill;
    v_against := v_use.against; v_damage_ok := v_use.deals_damage; v_fx := v_use.effect;
    IF v_skill IS NOT NULL AND cardinality(v_targets) = 0 THEN RAISE EXCEPTION 'choose who % is aimed at', v_act.name; END IF;
  ELSE
    IF p_stat_key IS NULL OR p_stat_key NOT IN ('attack', 'defense', 'strength', 'will', 'stealth', 'awareness', 'agility') THEN
      RAISE EXCEPTION 'choose one of the creature''s skills';
    END IF;
    v_skill := public.rpg_participant_value(p_actor_id, p_stat_key);
    IF v_skill IS NULL THEN RAISE EXCEPTION '% has no % skill on its card', v_actor.name, p_stat_key; END IF;
    v_kind := 'check'; v_key := initcap(p_stat_key); v_label := initcap(p_stat_key); v_against := p_against;
    v_diff := greatest(coalesce(p_difficulty, public.rpg_setting('default_difficulty')), 0);
    IF cardinality(v_targets) > 0 AND v_against IS NULL THEN RAISE EXCEPTION 'choose what it rolls against'; END IF;
  END IF;
  IF cardinality(v_targets) > 0 THEN
    SELECT name INTO v_against_name FROM public.rpg_stat_definitions WHERE key = v_against;
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown stat %', v_against; END IF;
  END IF;

  IF v_kind = 'action' AND v_skill IS NULL THEN
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, v_s.id, v_s.round, 'action', 'info', p_actor_id, v_actor.name || ' uses ' || v_act.name || '.');
  ELSIF cardinality(v_targets) = 0 THEN
    v_roll := public.rpg_roll(v_actor.character_id, v_key, v_diff, v_label, NULL, v_s.id, p_actor_id,
                              CASE WHEN v_actor.character_id IS NULL THEN v_skill END, p_roll);
    v_first := v_roll; v_extras := '{}'; v_i := 0; v_pending := false;
    IF p_roll IS NOT NULL THEN
      v_pending := coalesce((v_roll->>'extra_pending')::boolean, false);
    ELSE
      WHILE coalesce((v_roll->>'extra_pending')::boolean, false) AND v_i < 20 LOOP
        v_roll := public.rpg_roll_extra((v_roll->>'roll_id')::uuid);
        v_extras := v_extras || (v_roll->>'roll')::integer; v_i := v_i + 1;
      END LOOP;
    END IF;
    v_needs := ceil((v_first->>'needed')::numeric)::integer;
    v_out := public.rpg_outcome((v_first->>'roll')::integer, (v_first->>'needed')::numeric, (v_first->>'critical')::numeric, false, 0);
    v_levelup := CASE WHEN (v_roll->>'level_after')::integer > (v_first->>'level_before')::integer
                      THEN ' ' || v_actor.name || '''s ' || v_label || ' goes up to ' || (v_roll->>'level_after') || '!' ELSE '' END;
    v_tail := '';
    IF p_effect IS NOT NULL THEN
      IF v_first->>'result' <> '' THEN
        UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e WHERE e->>'name' <> p_effect)
         WHERE p.id = p_actor_id;
        v_tail := ' ' || v_actor.name || ' shakes off ' || p_effect || '.';
      ELSE
        UPDATE public.rpg_session_participants p
           SET effects = (SELECT coalesce(jsonb_agg(CASE WHEN e->>'name' = p_effect THEN e || jsonb_build_object('checked_round', v_s.round) ELSE e END), '[]'::jsonb)
                            FROM jsonb_array_elements(p.effects) e)
         WHERE p.id = p_actor_id;
        IF v_eff->>'on_fail' = 'no_attack' THEN
          UPDATE public.rpg_sessions SET turn_attacks = greatest(turn_attacks, v_per) WHERE id = v_s.id;
          v_tail := ' ' || v_actor.name || ' stays ' || p_effect || ' and cannot attack this turn.';
        ELSE
          v_tail := ' ' || v_actor.name || ' stays ' || p_effect || '.';
        END IF;
      END IF;
    END IF;
    v_xtext := CASE WHEN cardinality(v_extras) > 0 THEN ' Extra roll' || CASE WHEN cardinality(v_extras) > 1 THEN 's ' ELSE ' ' END || array_to_string(v_extras, ' and ') || '.' ELSE '' END;
    v_text := (v_out->>'label') || ': ' || v_actor.name || ' rolls ' || v_label || ' against ' || trim_scale(v_diff)
              || CASE WHEN p_effect IS NOT NULL THEN ' to shake off ' || p_effect ELSE '' END
              || '. Rolled ' || (v_first->>'roll') || ', needs ' || v_needs || '.' || v_xtext
              || CASE WHEN v_pending THEN ' Roll again and enter it.' ELSE '' END || v_tail || v_levelup;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, roll_id, text)
    VALUES (v_s.agency_id, v_s.id, v_s.round, 'check', v_out->>'key', p_actor_id, (v_first->>'roll_id')::uuid, v_text);
    v_results := v_results || jsonb_build_array(jsonb_build_object('roll_id', v_first->'roll_id', 'roll', v_first->'roll', 'needed', v_first->'needed',
                   'result', v_first->'result', 'outcome', v_out->>'key', 'extras', to_jsonb(v_extras), 'extra_pending', v_pending,
                   'difficulty', v_diff, 'text', v_text));
  ELSE
    FOREACH v_tid IN ARRAY v_targets LOOP
      SELECT * INTO v_t FROM public.rpg_session_participants WHERE id = v_tid;
      v_def := coalesce(public.rpg_participant_value(v_tid, v_against), 0);
      v_diff := public.rpg_difficulty(v_def, public.rpg_participant_can_act(v_tid));
      v_roll := public.rpg_roll(v_actor.character_id, v_key, v_diff, v_label, NULL, v_s.id, p_actor_id,
                                CASE WHEN v_actor.character_id IS NULL THEN v_skill END,
                                CASE WHEN cardinality(v_targets) = 1 THEN p_roll END);
      v_first := v_roll; v_extras := '{}'; v_i := 0; v_pending := false;
      IF p_roll IS NOT NULL AND cardinality(v_targets) = 1 THEN
        v_pending := coalesce((v_roll->>'extra_pending')::boolean, false);
      ELSE
        WHILE coalesce((v_roll->>'extra_pending')::boolean, false) AND v_i < 20 LOOP
          v_roll := public.rpg_roll_extra((v_roll->>'roll_id')::uuid);
          v_extras := v_extras || (v_roll->>'roll')::integer; v_i := v_i + 1;
        END LOOP;
      END IF;
      v_dmg := CASE WHEN v_damage_ok THEN public.rpg_damage((v_first->>'roll_id')::uuid) ELSE 0 END;
      IF v_dmg > 0 THEN v_vit := public.rpg_session_adjust_vitality(v_tid, v_dmg);
      ELSE v_vit := public.rpg_participant_vitality(v_tid); END IF;
      v_needs := ceil((v_first->>'needed')::numeric)::integer;
      v_out := public.rpg_outcome((v_first->>'roll')::integer, (v_first->>'needed')::numeric, (v_first->>'critical')::numeric, v_damage_ok, v_dmg);
      v_levelup := CASE WHEN v_actor.character_id IS NOT NULL AND (v_roll->>'level_after')::integer > (v_first->>'level_before')::integer
                        THEN ' ' || v_actor.name || '''s ' || v_label || ' goes up to ' || (v_roll->>'level_after') || '!' ELSE '' END;
      v_who := CASE v_kind
                 WHEN 'attack' THEN v_actor.name || ' attacks ' || v_t.name || ' with ' || v_label
                 WHEN 'action' THEN v_actor.name || '''s ' || v_label || ' at ' || v_t.name || CASE WHEN v_damage_ok THEN '' ELSE ' (' || v_against_name || ')' END
                 ELSE v_actor.name || ' rolls ' || v_label || ' against ' || v_t.name || '''s ' || v_against_name END;
      v_tail := CASE WHEN v_dmg > 0 AND (v_vit->>'left')::integer <= 0 THEN ' ' || v_t.name || ' is down.'
                     WHEN v_dmg > 0 AND v_t.character_id IS NOT NULL THEN ' ' || v_t.name || ' has ' || (v_vit->>'left') || ' left.'
                     ELSE '' END;
      IF v_kind = 'action' AND v_fx IS NOT NULL AND v_first->>'result' <> '' AND (v_vit->>'left')::integer > 0 THEN
        IF v_fx->>'on' = 'land' AND NOT v_damage_ok THEN
          PERFORM public.rpg_participant_apply_effect(v_tid, v_fx->'apply', v_label, v_s.round);
          v_tail := v_tail || ' ' || v_t.name || ' is ' || (v_fx->'apply'->>'name') || '.';
        ELSIF v_fx->>'on' = 'hit' AND v_dmg > 0 AND v_fx ? 'contest' THEN
          v_cskill := coalesce(public.rpg_participant_value(p_actor_id, v_fx->'contest'->>'skill_key'), 0);
          v_cdiff := public.rpg_difficulty(coalesce(public.rpg_participant_value(v_tid, v_fx->'contest'->>'against'), 0), public.rpg_participant_can_act(v_tid));
          v_croll := public.rpg_roll(NULL, initcap(v_fx->'contest'->>'skill_key'), v_cdiff, v_label || ' (' || (v_fx->'apply'->>'name') || ')', NULL, v_s.id, p_actor_id, v_cskill);
          IF v_croll->>'result' <> '' THEN
            PERFORM public.rpg_participant_apply_effect(v_tid, v_fx->'apply', v_label, v_s.round);
            v_tail := v_tail || ' ' || v_t.name || ' is ' || (v_fx->'apply'->>'name');
          ELSE
            v_tail := v_tail || ' ' || v_t.name || ' stays up';
          END IF;
          v_tail := v_tail || ' (' || initcap(v_fx->'contest'->>'skill_key') || ' ' || trim_scale(v_cskill) || ' against ' || trim_scale(v_cdiff)
                    || ': rolled ' || (v_croll->>'roll') || ', needs ' || ceil((v_croll->>'needed')::numeric) || ').';
        END IF;
      END IF;
      v_xtext := CASE WHEN cardinality(v_extras) > 0 THEN ' Extra roll' || CASE WHEN cardinality(v_extras) > 1 THEN 's ' ELSE ' ' END || array_to_string(v_extras, ' and ') || '.' ELSE '' END;
      v_text := (v_out->>'label') || CASE WHEN v_damage_ok AND v_dmg > 0 THEN ' for ' || v_dmg || CASE WHEN v_pending THEN ' so far' ELSE '' END ELSE '' END
                || ': ' || v_who || '. Rolled ' || (v_first->>'roll') || ', needs ' || v_needs || '.' || v_xtext
                || CASE WHEN v_pending THEN ' Roll again and enter it.' ELSE '' END || v_tail || v_levelup;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, target_id, roll_id, damage, text)
      VALUES (v_s.agency_id, v_s.id, v_s.round, v_kind, v_out->>'key', p_actor_id, v_tid, (v_first->>'roll_id')::uuid, v_dmg, v_text);
      v_results := v_results || jsonb_build_array(jsonb_build_object('roll_id', v_first->'roll_id', 'target_id', v_tid, 'target_name', v_t.name,
                     'roll', v_first->'roll', 'needed', v_first->'needed', 'result', v_first->'result', 'outcome', v_out->>'key',
                     'extras', to_jsonb(v_extras), 'extra_pending', v_pending, 'difficulty', v_diff, 'damage', v_dmg,
                     'down', (v_vit->>'left')::integer <= 0, 'text', v_text));
    END LOOP;
  END IF;

  IF v_kind = 'attack' THEN
    UPDATE public.rpg_sessions SET turn_attacks = turn_attacks + 1 WHERE id = v_s.id;
  END IF;
  IF v_kind = 'action' THEN
    UPDATE public.rpg_session_participants
       SET legendary_left = legendary_left - CASE WHEN v_act.kind = 'legendary' THEN v_act.legendary_cost ELSE 0 END,
           recharge_state = CASE WHEN v_act.recharge_min IS NOT NULL
                                 THEN recharge_state || jsonb_build_object(v_act.id::text, true) ELSE recharge_state END
     WHERE id = p_actor_id;
  END IF;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_s.id;
  RETURN jsonb_build_object('kind', v_kind, 'label', v_label, 'results', v_results);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_act_extra(p_roll_id uuid, p_roll integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Enters the extra die a critical asked for when the first die was rolled by hand. The extra roll goes through
-- rpg_roll_extra; on an attack its result is that much more damage to the same target. Another critical asks again.
-- A Claw that hit for 50 so far with an extra roll of 22 → 22 more damage, 72 in all.
DECLARE v_ev record; v_p record; v_s record; v_x jsonb; v_vit jsonb; v_dmg integer := 0; v_text text; v_tail text := '';
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_ev FROM public.rpg_events WHERE roll_id = p_roll_id ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'that roll is not in a fight'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = v_ev.actor_id;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_ev.session_id FOR UPDATE;
  IF v_s.status <> 'active' THEN RAISE EXCEPTION 'that fight is not on'; END IF;
  IF NOT public.family_is_parent() AND (v_p.character_id IS NULL OR v_s.current_participant_id IS DISTINCT FROM v_p.id) THEN
    RAISE EXCEPTION 'it is not %''s turn', v_p.name;
  END IF;
  v_x := public.rpg_roll_extra(p_roll_id, p_roll);
  IF coalesce(v_ev.damage, 0) > 0 AND v_ev.target_id IS NOT NULL THEN
    v_dmg := (v_x->>'roll')::integer;
    v_vit := public.rpg_session_adjust_vitality(v_ev.target_id, v_dmg);
    v_tail := ' ' || v_dmg || ' more damage to ' || (SELECT name FROM public.rpg_session_participants WHERE id = v_ev.target_id) || '.'
              || CASE WHEN (v_vit->>'left')::integer <= 0 THEN ' They are down.' ELSE '' END;
  END IF;
  v_text := 'Extra roll ' || (v_x->>'roll') || ': ' || v_p.name || '''s critical.' || v_tail
            || CASE WHEN coalesce((v_x->>'extra_pending')::boolean, false) THEN ' Another critical! Roll again and enter it.' ELSE '' END;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, target_id, roll_id, damage, text)
  VALUES (v_s.agency_id, v_s.id, v_s.round, v_ev.kind, 'critical', v_ev.actor_id, v_ev.target_id, (v_x->>'roll_id')::uuid, nullif(v_dmg, 0), v_text);
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_s.id;
  RETURN jsonb_build_object('kind', v_ev.kind, 'results', jsonb_build_array(jsonb_build_object(
    'roll_id', v_x->'roll_id', 'roll', v_x->'roll', 'outcome', 'critical', 'extra_pending', v_x->'extra_pending', 'damage', v_dmg, 'text', v_text)));
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_next_turn(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Ends the current turn and starts the next one in turn order; after the last one a new round begins at the top.
-- In setup this starts the fight at round 1. A new round frees anyone Held from an earlier round. At the start of
-- someone's turn they get up from Knocked down. When a creature's turn starts its legendary actions come back
-- (Bramblemaw: 3) and each recharge action it has used rolls a six-sided die: Briar Roar is ready again on 5 or 6.
-- The game master can pass any turn; a player can end a character's turn.
DECLARE
  v_s record; v_cur_id uuid; v_cur_order integer; v_cur_created timestamptz; v_cur_char uuid;
  v_next_id uuid; v_round integer; v_new_round boolean := false; v_next record; v_state jsonb; v_a record; v_d6 integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  SELECT id, turn_order, created_at, character_id INTO v_cur_id, v_cur_order, v_cur_created, v_cur_char
    FROM public.rpg_session_participants WHERE id = v_s.current_participant_id AND session_id = p_session_id;
  IF NOT public.family_is_parent() THEN
    IF v_s.status <> 'active' THEN RAISE EXCEPTION 'the game master starts the fight'; END IF;
    IF v_cur_id IS NULL OR v_cur_char IS NULL THEN RAISE EXCEPTION 'the game master ends this turn'; END IF;
  END IF;
  v_round := greatest(v_s.round, 1);
  IF v_s.status = 'active' AND v_cur_id IS NOT NULL THEN
    SELECT id INTO v_next_id FROM public.rpg_session_participants
     WHERE session_id = p_session_id AND (turn_order, created_at) > (v_cur_order, v_cur_created)
     ORDER BY turn_order, created_at LIMIT 1;
  END IF;
  IF v_next_id IS NULL THEN
    SELECT id INTO v_next_id FROM public.rpg_session_participants WHERE session_id = p_session_id
     ORDER BY turn_order, created_at LIMIT 1;
    IF v_next_id IS NULL THEN RAISE EXCEPTION 'add someone to the fight first'; END IF;
    IF v_s.status = 'active' THEN v_round := v_s.round + 1; v_new_round := true; END IF;
  END IF;
  UPDATE public.rpg_sessions SET status = 'active', round = v_round, current_participant_id = v_next_id,
         turn_attacks = 0, updated_at = now()
   WHERE id = p_session_id;
  IF v_s.status = 'setup' THEN
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, text)
    VALUES (v_s.agency_id, p_session_id, v_round, 'start', 'info', 'The fight begins. Round 1.');
  ELSIF v_new_round THEN
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, text)
    VALUES (v_s.agency_id, p_session_id, v_round, 'round', 'info', 'Round ' || v_round || ' begins.');
    FOR v_a IN SELECT p.id, p.name, e->>'name' AS ename FROM public.rpg_session_participants p, jsonb_array_elements(p.effects) e
                WHERE p.session_id = p_session_id AND e->>'clear' = 'round' AND (e->>'round')::integer < v_round LOOP
      UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e WHERE e->>'name' <> v_a.ename)
       WHERE p.id = v_a.id;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_round, 'effect', 'info', v_a.id, v_a.name || ' is no longer ' || v_a.ename || '.');
    END LOOP;
  END IF;
  SELECT * INTO v_next FROM public.rpg_session_participants WHERE id = v_next_id;
  FOR v_a IN SELECT e->>'name' AS ename FROM jsonb_array_elements(v_next.effects) e WHERE e->>'clear' = 'turn_start' LOOP
    UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e WHERE e->>'name' <> v_a.ename)
     WHERE p.id = v_next_id;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, p_session_id, v_round, 'effect', 'info', v_next_id, v_next.name || ' gets up. No longer ' || v_a.ename || '.');
  END LOOP;
  IF v_next.creature_id IS NOT NULL THEN
    v_state := v_next.recharge_state;
    FOR v_a IN SELECT a.id, a.name, a.recharge_min FROM public.rpg_creature_actions a
                WHERE a.creature_id = v_next.creature_id AND a.recharge_min IS NOT NULL AND v_state ? a.id::text
                ORDER BY a.sort_order LOOP
      v_d6 := floor(random() * 6)::integer + 1;
      IF v_d6 >= v_a.recharge_min THEN v_state := v_state - v_a.id::text; END IF;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_round, 'recharge', 'info', v_next_id,
              v_next.name || ' rolls a six-sided die for ' || v_a.name || ': ' || v_d6 || '. '
              || CASE WHEN v_d6 >= v_a.recharge_min THEN 'Ready again.' ELSE 'Not yet, it needs ' || v_a.recharge_min || ' or more.' END);
    END LOOP;
    UPDATE public.rpg_session_participants
       SET legendary_left = coalesce((SELECT legendary_per_round FROM public.rpg_creatures WHERE id = v_next.creature_id), 0),
           recharge_state = v_state
     WHERE id = v_next_id;
  END IF;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  VALUES (v_s.agency_id, p_session_id, v_round, 'turn', 'info', v_next_id, v_next.name || '''s turn.');
  RETURN jsonb_build_object('round', v_round, 'current_participant_id', v_next_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_auto_turn(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The site plays a creature's whole turn from its card, then passes the turn. It aims at characters who are still
-- up. A lair action with a roll (Grasping Roots) is tried one time in three. Then its main action: a ready recharge
-- action (Briar Roar) half the time, otherwise Multiattack rolled one attack at a time at random targets (two Claws
-- and a Bite), otherwise one other action at random. Every roll goes through rpg_act, so the log reads the same as
-- a hand-played turn. Legendary actions stay with the game master.
DECLARE
  v_s record; v_p record; v_a record; v_pick record; v_targets uuid[]; v_t uuid; v_n integer; v_e jsonb; v_lines jsonb := '[]'::jsonb; v_r jsonb;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master runs a creature''s turn'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND OR v_s.status <> 'active' THEN RAISE EXCEPTION 'the fight is not on'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = v_s.current_participant_id;
  IF NOT FOUND OR v_p.creature_id IS NULL THEN RAISE EXCEPTION 'it is not a creature''s turn'; END IF;
  SELECT array_agg(p.id) INTO v_targets FROM public.rpg_session_participants p
   WHERE p.session_id = p_session_id AND p.character_id IS NOT NULL AND (public.rpg_participant_vitality(p.id)->>'left')::integer > 0;
  IF NOT public.rpg_participant_can_act(v_p.id) THEN
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' cannot act this turn.');
  ELSIF coalesce(cardinality(v_targets), 0) = 0 THEN
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' has no one left to attack.');
  ELSE
    SELECT * INTO v_pick FROM public.rpg_creature_actions a
     WHERE a.creature_id = v_p.creature_id AND a.kind = 'lair' AND a.skill IS NOT NULL AND a.against IS NOT NULL ORDER BY random() LIMIT 1;
    IF FOUND AND random() < 1.0 / 3 THEN
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' uses its lair: ' || v_pick.name || '.');
      v_r := public.rpg_act(v_p.id, v_targets, NULL, v_pick.id);
      v_lines := v_lines || (v_r->'results');
    END IF;
    SELECT * INTO v_pick FROM public.rpg_creature_actions a
     WHERE a.creature_id = v_p.creature_id AND a.kind = 'action' AND a.recharge_min IS NOT NULL AND a.skill IS NOT NULL AND a.against IS NOT NULL
       AND NOT (v_p.recharge_state ? a.id::text) ORDER BY random() LIMIT 1;
    IF FOUND AND random() < 0.5 THEN
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' chooses ' || v_pick.name || '.');
      v_r := public.rpg_act(v_p.id, v_targets, NULL, v_pick.id);
      v_lines := v_lines || (v_r->'results');
    ELSE
      SELECT * INTO v_pick FROM public.rpg_creature_actions a
       WHERE a.creature_id = v_p.creature_id AND a.kind = 'action' AND jsonb_typeof(a.makes_attacks) = 'array' AND jsonb_array_length(a.makes_attacks) > 0
       ORDER BY a.sort_order LIMIT 1;
      IF FOUND THEN
        INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
        VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' chooses ' || v_pick.name || '.');
        FOR v_e IN SELECT e FROM jsonb_array_elements(v_pick.makes_attacks) e LOOP
          FOR v_n IN 1..greatest(coalesce((v_e->>'count')::integer, 1), 1) LOOP
            SELECT p.id INTO v_t FROM public.rpg_session_participants p
             WHERE p.id = ANY (v_targets) AND (public.rpg_participant_vitality(p.id)->>'left')::integer > 0 ORDER BY random() LIMIT 1;
            EXIT WHEN v_t IS NULL;
            SELECT * INTO v_a FROM public.rpg_creature_actions WHERE creature_id = v_p.creature_id AND name = v_e->>'action' LIMIT 1;
            IF FOUND THEN
              v_r := public.rpg_act(v_p.id, ARRAY[v_t], NULL, v_a.id);
              v_lines := v_lines || (v_r->'results');
            END IF;
          END LOOP;
        END LOOP;
      ELSE
        SELECT * INTO v_pick FROM public.rpg_creature_actions a
         WHERE a.creature_id = v_p.creature_id AND a.kind = 'action' AND a.skill IS NOT NULL AND a.against IS NOT NULL
           AND (a.recharge_min IS NULL OR NOT (v_p.recharge_state ? a.id::text)) ORDER BY random() LIMIT 1;
        IF FOUND THEN
          INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
          VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' chooses ' || v_pick.name || '.');
          SELECT p.id INTO v_t FROM public.rpg_session_participants p WHERE p.id = ANY (v_targets) ORDER BY random() LIMIT 1;
          v_r := public.rpg_act(v_p.id, CASE WHEN v_pick.deals_damage THEN ARRAY[v_t] ELSE v_targets END, NULL, v_pick.id);
          v_lines := v_lines || (v_r->'results');
        END IF;
      END IF;
    END IF;
  END IF;
  PERFORM public.rpg_session_next_turn(p_session_id);
  RETURN jsonb_build_object('kind', 'auto', 'results', v_lines);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_state(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Everything the Play tab shows for one fight in one read: the fight, everyone in turn order with their effects and
-- whether they can act, a character's pending check (Frightened → Courage against 8, needs 54), the last 60 log
-- lines with their outcome keys. Players get creatures without their numbers and no game-master lists.
DECLARE
  v_gm boolean := public.family_is_parent();
  v_s record; v_p record; v_sheet jsonb; v_c record; v_vit jsonb; v_item jsonb; v_parts jsonb := '[]'::jsonb;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  FOR v_p IN SELECT * FROM public.rpg_session_participants WHERE session_id = p_session_id ORDER BY turn_order, created_at LOOP
    IF v_p.character_id IS NOT NULL THEN
      v_sheet := public.rpg_sheet(v_p.character_id, public.rpg_setting('default_difficulty'));
      v_item := jsonb_build_object('kind', 'character', 'character_id', v_p.character_id, 'color', v_sheet->'color',
        'vitality_max', (v_sheet->>'vitality_max')::integer,
        'vitality_left', greatest((v_sheet->>'vitality_left')::integer, 0),
        'agility', (SELECT s->'value' FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = 'AG'),
        'weapons', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', s->>'key', 'name', s->>'name', 'value', s->'value')
                                    ORDER BY (s->>'value')::numeric DESC, s->>'name'), '[]'::jsonb)
                      FROM jsonb_array_elements(v_sheet->'stats') s
                      JOIN public.rpg_stat_definitions d ON d.key = s->>'key' AND d.is_attack),
        'pending_check', (SELECT jsonb_build_object('name', e->>'name', 'stat', e->>'check_stat', 'stat_name', d.name,
                            'difficulty', (e->>'check_difficulty')::numeric,
                            'skill', (SELECT s->'value' FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = e->>'check_stat'),
                            'needed', public.rpg_needed((SELECT (s->>'value')::numeric FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = e->>'check_stat'),
                                                        (e->>'check_difficulty')::numeric)->'needed')
                            FROM jsonb_array_elements(v_p.effects) e JOIN public.rpg_stat_definitions d ON d.key = e->>'check_stat'
                           WHERE e->>'clear' = 'check' AND (e->>'checked_round')::integer IS DISTINCT FROM v_s.round LIMIT 1));
    ELSE
      SELECT * INTO v_c FROM public.rpg_creatures WHERE id = v_p.creature_id;
      v_vit := public.rpg_participant_vitality(v_p.id);
      v_item := jsonb_build_object('kind', 'creature', 'creature_id', v_p.creature_id, 'color', v_c.color,
        'vitality_share', CASE WHEN (v_vit->>'max')::numeric > 0 THEN round((v_vit->>'left')::numeric / (v_vit->>'max')::numeric, 3) END);
      IF v_gm THEN
        v_item := v_item || jsonb_build_object(
          'vitality_max', (v_vit->>'max')::integer, 'vitality_left', (v_vit->>'left')::integer,
          'legendary_left', v_p.legendary_left, 'legendary_per_round', v_c.legendary_per_round, 'agility', v_c.agility_skill,
          'skills', jsonb_build_object('attack', v_c.attack_skill, 'defense', v_c.defense_skill, 'strength', v_c.strength_skill,
                                       'will', v_c.will_skill, 'stealth', v_c.stealth_skill, 'awareness', v_c.awareness_skill, 'agility', v_c.agility_skill),
          'actions', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                          'id', a.id, 'name', a.name, 'kind', a.kind, 'skill', coalesce(u.skill, a.skill),
                          'against', coalesce(u.against, a.against), 'against_name', d.name,
                          'deals_damage', coalesce(u.deals_damage, a.deals_damage), 'table_note', a.table_note,
                          'effect', coalesce(u.effect, a.effect)->'apply'->>'name',
                          'recharge_min', a.recharge_min, 'spent', v_p.recharge_state ? a.id::text, 'legendary_cost', a.legendary_cost,
                          'several', jsonb_array_length(coalesce(a.makes_attacks, '[]'::jsonb)) > 1 OR coalesce((a.makes_attacks->0->>'count')::integer, 1) > 1)
                        ORDER BY CASE a.kind WHEN 'action' THEN 1 WHEN 'bonus_action' THEN 2 WHEN 'reaction' THEN 3 WHEN 'legendary' THEN 4 WHEN 'lair' THEN 5 ELSE 6 END, a.sort_order), '[]'::jsonb)
                        FROM public.rpg_creature_actions a
                        LEFT JOIN public.rpg_creature_actions u ON u.creature_id = a.creature_id AND u.name = a.makes_attacks->0->>'action'
                              AND jsonb_array_length(coalesce(a.makes_attacks, '[]'::jsonb)) = 1
                        LEFT JOIN public.rpg_stat_definitions d ON d.key = coalesce(u.against, a.against)
                       WHERE a.creature_id = v_p.creature_id AND a.kind <> 'trait'));
      END IF;
    END IF;
    v_parts := v_parts || jsonb_build_array(jsonb_build_object('id', v_p.id, 'name', v_p.name, 'turn_order', v_p.turn_order,
                 'can_act', v_p.can_act, 'status_note', v_p.status_note, 'can_act_now', public.rpg_participant_can_act(v_p.id),
                 'effects', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', e->>'name', 'cannot_act', coalesce((e->>'cannot_act')::boolean, false), 'source', e->>'source')), '[]'::jsonb)
                               FROM jsonb_array_elements(v_p.effects) e),
                 'is_current', coalesce(v_p.id = v_s.current_participant_id, false)) || v_item);
  END LOOP;
  RETURN jsonb_build_object(
    'session', jsonb_build_object('id', v_s.id, 'name', v_s.name, 'status', v_s.status, 'round', v_s.round,
                 'current_participant_id', v_s.current_participant_id, 'turn_attacks', v_s.turn_attacks,
                 'attacks_per_turn', public.rpg_setting('attacks_per_turn'), 'updated_at', v_s.updated_at),
    'is_gm', v_gm,
    'participants', v_parts,
    'events', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'round', e.round, 'kind', e.kind, 'outcome', e.outcome, 'text', e.text,
                                          'damage', e.damage, 'created_at', e.created_at) ORDER BY e.created_at DESC), '[]'::jsonb)
                 FROM (SELECT * FROM public.rpg_events WHERE session_id = p_session_id ORDER BY created_at DESC LIMIT 60) e),
    'available', CASE WHEN v_gm THEN jsonb_build_object(
        'characters', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) ORDER BY c.name), '[]'::jsonb)
                         FROM public.rpg_characters c
                        WHERE c.is_active AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants p WHERE p.session_id = p_session_id AND p.character_id = c.id)),
        'creatures', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) ORDER BY c.sort_order, c.name), '[]'::jsonb)
                        FROM public.rpg_creatures c WHERE c.is_active)) END);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpg_roll(uuid, text, numeric, text, uuid, uuid, uuid, numeric, integer), public.rpg_roll_extra(uuid, integer),
  public.rpg_act(uuid, uuid[], text, uuid, text, numeric, integer, text), public.rpg_act_extra(uuid, integer),
  public.rpg_participant_can_act(uuid), public.rpg_participant_apply_effect(uuid, jsonb, text, integer),
  public.rpg_outcome(integer, numeric, numeric, boolean, integer), public.rpg_session_auto_turn(uuid),
  public.rpg_session_next_turn(uuid), public.rpg_session_state(uuid) TO authenticated;

-- In-place edits of two existing functions, checked against their anchors.
DO $do$
DECLARE v_src text; v_anchor text := '''key'', r.key, ''title'', r.title, ''body'', r.body, ''source'', r.source)';
BEGIN
  v_src := pg_get_functiondef('public.rpg_rules_page'::regproc);
  IF position('''section'', r.section' IN v_src) > 0 THEN RETURN; END IF;
  IF position(v_anchor IN v_src) = 0 THEN RAISE EXCEPTION 'rpg_rules_page anchor not found'; END IF;
  EXECUTE replace(v_src, v_anchor, '''key'', r.key, ''title'', r.title, ''body'', r.body, ''source'', r.source, ''section'', r.section)');
END $do$;
DO $do$
DECLARE v_src text; v_anchor text := 'IF NOT v_gm THEN RETURN v_card; END IF;';
BEGIN
  v_src := pg_get_functiondef('public.rpg_creature_card'::regproc);
  IF position('''image_path''' IN v_src) > 0 THEN RETURN; END IF;
  IF position(v_anchor IN v_src) = 0 THEN RAISE EXCEPTION 'rpg_creature_card anchor not found'; END IF;
  EXECUTE replace(v_src, v_anchor, 'v_card := v_card || jsonb_build_object(''image_path'', v_c.image_path);' || E'\n  ' || v_anchor);
END $do$;

-- Guard: one of each rolling function, every rpg_ function callable when signed in, both edits in place.
DO $do$
BEGIN
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'rpg_roll') <> 1 THEN RAISE EXCEPTION 'rpg_roll has overloads'; END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'rpg_act') <> 1 THEN RAISE EXCEPTION 'rpg_act has overloads'; END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'rpg_roll_extra') <> 1 THEN RAISE EXCEPTION 'rpg_roll_extra has overloads'; END IF;
  IF NOT (SELECT bool_and(has_function_privilege('authenticated', p.oid, 'EXECUTE')) FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'rpg\_%' AND p.prorettype <> 'trigger'::regtype AND p.proname <> 'rpg_manual_page_sync') THEN
    RAISE EXCEPTION 'an rpg_ function lost its grant';
  END IF;
  IF position('''section'', r.section' IN pg_get_functiondef('public.rpg_rules_page'::regproc)) = 0 THEN RAISE EXCEPTION 'rules page has no section'; END IF;
  IF position('''image_path''' IN pg_get_functiondef('public.rpg_creature_card'::regproc)) = 0 THEN RAISE EXCEPTION 'creature card has no image_path'; END IF;
END $do$;
