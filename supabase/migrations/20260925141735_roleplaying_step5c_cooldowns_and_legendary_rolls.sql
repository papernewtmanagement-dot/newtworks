-- Roleplaying step 5c: cooldowns on every creature action, legendary actions by die roll (Peter 2026-09-25).
-- Every action on a card has a recharge number. After a creature uses an action it is spent; at the start of its
-- next turn a six-sided die is rolled for each spent action and it comes back on that number or more (Multiattack
-- 2+, Briar Roar 5+, Grasping Roots 4+). Multiattack rolls all of its attacks in one go so it can be one action with
-- one cooldown; a creature gets one main action a turn. At the end of every turn that is not its own, a creature
-- with legendary actions left rolls a six-sided die; on 4 or more it spends one on a ready move it can afford.
-- The engine flag lets those rule-driven creature rolls run when a player ends their turn.

ALTER TABLE public.rpg_creature_actions ALTER COLUMN recharge_min SET DEFAULT 2;
UPDATE public.rpg_creature_actions SET recharge_min = CASE name
    WHEN 'Rending Swipe' THEN 3 WHEN 'Sink Into Soil' THEN 4 WHEN 'Grasping Roots' THEN 4 WHEN 'Living Silence' THEN 4 WHEN 'Briar Shift' THEN 4
    WHEN 'Shell Slam' THEN 3 WHEN 'Lure' THEN 4 WHEN 'Charge' THEN 3 ELSE 2 END
 WHERE recharge_min IS NULL AND kind <> 'trait';
UPDATE public.rpg_rules
   SET body = body || E'\n\nA creature''s actions cool down. After it uses one, that action is spent until a six-sided die rolled at the start of its next turn comes up its number or more: Multiattack on 2 or more, Briar Roar on 5 or more. A creature takes one main action a turn. Its legendary actions come from a roll too: at the end of anyone else''s turn the site rolls a six-sided die for it, and on 4 or more it spends one (Rending Swipe: one Claw), up to its number a round.'
 WHERE key = 'turn_order' AND body NOT LIKE '%actions cool down%';

CREATE OR REPLACE FUNCTION public.rpg_roll(p_character_id uuid, p_stat_key text, p_difficulty numeric DEFAULT NULL::numeric,
  p_label text DEFAULT NULL::text, p_parent_roll_id uuid DEFAULT NULL::uuid, p_session_id uuid DEFAULT NULL::uuid,
  p_participant_id uuid DEFAULT NULL::uuid, p_skill numeric DEFAULT NULL::numeric, p_roll integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One d100 roll. A character rolls a stat from their sheet and earns skill points on a trainable one, every roll:
-- die × Needed ÷ 100 (Peter 2026-09-24). A creature in a fight (no character; its participant and skill passed in)
-- rolls the skill it is handed, earns nothing, and only the game master or the rules engine (rpg.engine flag, set
-- by the turn functions) rolls it. p_roll is a die rolled by hand (1 to 100) used in place of the random one.
-- Needed comes from rpg_needed; an opponent's difficulty arrives already derived by rpg_difficulty.
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
    IF NOT (public.family_is_parent() OR current_setting('rpg.engine', true) = 'on') THEN RAISE EXCEPTION 'only the game master rolls for a creature'; END IF;
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

CREATE OR REPLACE FUNCTION public.rpg_act(p_actor_id uuid, p_target_ids uuid[] DEFAULT NULL::uuid[], p_stat_key text DEFAULT NULL::text,
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
--   deals_damage actions hurt. An action that makes several attacks (Multiattack: 2 × Claw, 1 × Bite) rolls each one
--   here, at the target given or spread at random over the targets given. A landed action's effect goes on the
--   target: on "land" outright (Briar Roar → Frightened), on "hit" after a contest roll (Claw hit → Strength 10
--   against their Strength × 2 → Knocked down). One main action a turn (attacks_per_turn). Every action is spent
--   after use until its six-sided die at the start of the creature's next turn (recharge_min). Legendary actions
--   spend legendary_left and are used on other turns, by the game master or the rules engine (rpg.engine flag).
--   An action with no roll is used without one. A creature can also roll one of its own skills against a target's stat.
-- p_roll is a die rolled by hand: with it, a critical waits for its extra roll (rpg_act_extra) instead of rolling
-- it here. The log leads with rpg_outcome's word: Big hit for 28, Miss, Success.
DECLARE
  v_gm boolean := public.family_is_parent() OR current_setting('rpg.engine', true) = 'on';
  v_actor record; v_s record; v_act record; v_use record; v_t record;
  v_targets uuid[] := coalesce(p_target_ids, '{}'::uuid[]);
  v_kind text; v_key text; v_label text; v_skill numeric; v_against text; v_against_name text;
  v_damage_ok boolean := false; v_is_attack boolean := false; v_stat_name text;
  v_tid uuid; v_cid uuid; v_def numeric; v_diff numeric; v_roll jsonb; v_first jsonb; v_extras integer[]; v_i integer;
  v_dmg integer; v_vit jsonb; v_text text; v_needs integer; v_results jsonb := '[]'::jsonb; v_levelup text;
  v_eff jsonb; v_fx jsonb; v_out jsonb; v_pending boolean; v_tail text; v_who text; v_xtext text;
  v_croll jsonb; v_cskill numeric; v_cdiff numeric; v_per integer := public.rpg_setting('attacks_per_turn')::integer;
  v_plan jsonb := '[]'::jsonb; v_step jsonb; v_e jsonb; v_n integer;
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
    IF v_act.kind = 'legendary' AND v_actor.legendary_left < v_act.legendary_cost THEN
      RAISE EXCEPTION '% has % legendary actions left and % costs %', v_actor.name, v_actor.legendary_left, v_act.name, v_act.legendary_cost;
    END IF;
    IF v_act.recharge_min IS NOT NULL AND v_actor.recharge_state ? v_act.id::text THEN
      RAISE EXCEPTION '% is not ready. It comes back on a six-sided die roll of % or more at the start of %''s turn',
        v_act.name, v_act.recharge_min, v_actor.name;
    END IF;
    IF v_act.kind = 'action' AND v_s.current_participant_id = p_actor_id AND v_s.turn_attacks >= v_per THEN
      RAISE EXCEPTION '% has already taken its action this turn', v_actor.name;
    END IF;
    v_kind := 'action'; v_label := v_act.name;
    IF jsonb_typeof(v_act.makes_attacks) = 'array' AND jsonb_array_length(v_act.makes_attacks) > 0 THEN
      IF cardinality(v_targets) = 0 THEN RAISE EXCEPTION 'choose who % is aimed at', v_act.name; END IF;
      FOR v_e IN SELECT e FROM jsonb_array_elements(v_act.makes_attacks) e LOOP
        SELECT id INTO v_cid FROM public.rpg_creature_actions WHERE creature_id = v_actor.creature_id AND name = v_e->>'action' LIMIT 1;
        IF NOT FOUND THEN RAISE EXCEPTION '% names an attack that is not on the card', v_act.name; END IF;
        FOR v_n IN 1..greatest(coalesce((v_e->>'count')::integer, 1), 1) LOOP
          v_plan := v_plan || jsonb_build_object('a', v_cid, 't', v_targets[1 + floor(random() * cardinality(v_targets))::integer]);
        END LOOP;
      END LOOP;
    ELSIF v_act.skill IS NOT NULL THEN
      IF cardinality(v_targets) = 0 THEN RAISE EXCEPTION 'choose who % is aimed at', v_act.name; END IF;
      FOREACH v_tid IN ARRAY v_targets LOOP v_plan := v_plan || jsonb_build_object('a', v_act.id, 't', v_tid); END LOOP;
    END IF;
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
  IF v_kind <> 'action' THEN
    FOREACH v_tid IN ARRAY v_targets LOOP v_plan := v_plan || jsonb_build_object('t', v_tid); END LOOP;
    IF cardinality(v_targets) > 0 THEN
      SELECT name INTO v_against_name FROM public.rpg_stat_definitions WHERE key = v_against;
      IF NOT FOUND THEN RAISE EXCEPTION 'unknown stat %', v_against; END IF;
    END IF;
  END IF;

  IF v_kind = 'action' AND jsonb_array_length(v_plan) = 0 THEN
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
    FOR v_step IN SELECT s FROM jsonb_array_elements(v_plan) s LOOP
      v_tid := (v_step->>'t')::uuid;
      IF v_kind = 'action' THEN
        SELECT * INTO v_use FROM public.rpg_creature_actions WHERE id = (v_step->>'a')::uuid;
        IF v_use.skill IS NULL THEN RAISE EXCEPTION '% has no roll on the card', v_use.name; END IF;
        v_key := v_use.name; v_skill := v_use.skill; v_against := v_use.against; v_damage_ok := coalesce(v_use.deals_damage, false); v_fx := v_use.effect;
        SELECT name INTO v_against_name FROM public.rpg_stat_definitions WHERE key = v_against;
        IF NOT FOUND THEN RAISE EXCEPTION 'unknown stat %', v_against; END IF;
      END IF;
      SELECT * INTO v_t FROM public.rpg_session_participants WHERE id = v_tid;
      v_def := coalesce(public.rpg_participant_value(v_tid, v_against), 0);
      v_diff := public.rpg_difficulty(v_def, public.rpg_participant_can_act(v_tid));
      v_roll := public.rpg_roll(v_actor.character_id, v_key, v_diff, v_label, NULL, v_s.id, p_actor_id,
                                CASE WHEN v_actor.character_id IS NULL THEN v_skill END,
                                CASE WHEN jsonb_array_length(v_plan) = 1 THEN p_roll END);
      v_first := v_roll; v_extras := '{}'; v_i := 0; v_pending := false;
      IF p_roll IS NOT NULL AND jsonb_array_length(v_plan) = 1 THEN
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
                 WHEN 'action' THEN v_actor.name || '''s ' || v_use.name || CASE WHEN v_use.id <> v_act.id THEN ' (' || v_act.name || ')' ELSE '' END
                                    || ' at ' || v_t.name || CASE WHEN v_damage_ok THEN '' ELSE ' (' || v_against_name || ')' END
                 ELSE v_actor.name || ' rolls ' || v_label || ' against ' || v_t.name || '''s ' || v_against_name END;
      v_tail := CASE WHEN v_dmg > 0 AND (v_vit->>'left')::integer <= 0 THEN ' ' || v_t.name || ' is down.'
                     WHEN v_dmg > 0 AND v_t.character_id IS NOT NULL THEN ' ' || v_t.name || ' has ' || (v_vit->>'left') || ' left.'
                     ELSE '' END;
      IF v_kind = 'action' AND v_fx IS NOT NULL AND v_first->>'result' <> '' AND (v_vit->>'left')::integer > 0 THEN
        IF v_fx->>'on' = 'land' AND NOT v_damage_ok THEN
          PERFORM public.rpg_participant_apply_effect(v_tid, v_fx->'apply', v_use.name, v_s.round);
          v_tail := v_tail || ' ' || v_t.name || ' is ' || (v_fx->'apply'->>'name') || '.';
        ELSIF v_fx->>'on' = 'hit' AND v_dmg > 0 AND v_fx ? 'contest' THEN
          v_cskill := coalesce(public.rpg_participant_value(p_actor_id, v_fx->'contest'->>'skill_key'), 0);
          v_cdiff := public.rpg_difficulty(coalesce(public.rpg_participant_value(v_tid, v_fx->'contest'->>'against'), 0), public.rpg_participant_can_act(v_tid));
          v_croll := public.rpg_roll(NULL, initcap(v_fx->'contest'->>'skill_key'), v_cdiff, v_use.name || ' (' || (v_fx->'apply'->>'name') || ')', NULL, v_s.id, p_actor_id, v_cskill);
          IF v_croll->>'result' <> '' THEN
            PERFORM public.rpg_participant_apply_effect(v_tid, v_fx->'apply', v_use.name, v_s.round);
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

  IF v_kind = 'attack' OR (v_kind = 'action' AND v_act.kind = 'action' AND v_s.current_participant_id = p_actor_id) THEN
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

CREATE OR REPLACE FUNCTION public.rpg_session_next_turn(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Ends the current turn and starts the next one in turn order; after the last one a new round begins at the top.
-- In setup this starts the fight at round 1. As a turn ends, every other creature with legendary actions left
-- rolls a six-sided die: on 4 or more it spends one on a ready move it can afford (Rending Swipe: one Claw at a
-- random character). A new round frees anyone Held from an earlier round. At the start of someone's turn they get
-- up from Knocked down. When a creature's turn starts its legendary actions come back (Bramblemaw: 3) and each
-- spent action rolls a six-sided die to come back: Multiattack on 2 or more, Briar Roar on 5 or more.
-- The game master can pass any turn; a player can end a character's turn.
DECLARE
  v_s record; v_cur_id uuid; v_cur_order integer; v_cur_created timestamptz; v_cur_char uuid;
  v_next_id uuid; v_round integer; v_new_round boolean := false; v_next record; v_state jsonb; v_a record; v_la record;
  v_d6 integer; v_tg uuid[]; v_txt text;
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

  IF v_s.status = 'active' AND v_cur_id IS NOT NULL THEN
    PERFORM set_config('rpg.engine', 'on', true);
    FOR v_a IN SELECT p.id, p.name, p.legendary_left, p.creature_id, p.recharge_state FROM public.rpg_session_participants p
                WHERE p.session_id = p_session_id AND p.creature_id IS NOT NULL AND p.id <> v_cur_id AND p.legendary_left > 0
                  AND public.rpg_participant_can_act(p.id) LOOP
      SELECT a.* INTO v_la FROM public.rpg_creature_actions a
       WHERE a.creature_id = v_a.creature_id AND a.kind = 'legendary' AND a.legendary_cost <= v_a.legendary_left
         AND NOT (v_a.recharge_state ? a.id::text)
         AND (a.skill IS NOT NULL OR jsonb_typeof(a.makes_attacks) = 'array' OR a.effect IS NOT NULL)
       ORDER BY random() LIMIT 1;
      CONTINUE WHEN NOT FOUND;
      v_d6 := floor(random() * 6)::integer + 1;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_s.round, 'legendary', 'info', v_a.id,
              v_a.name || ' rolls a six-sided die to react: ' || v_d6 || '. ' || CASE WHEN v_d6 >= 4 THEN 'It uses ' || v_la.name || '.' ELSE 'It holds back.' END);
      IF v_d6 >= 4 THEN
        SELECT array_agg(p.id) INTO v_tg FROM public.rpg_session_participants p
         WHERE p.session_id = p_session_id AND p.character_id IS NOT NULL AND (public.rpg_participant_vitality(p.id)->>'left')::integer > 0;
        IF v_tg IS NOT NULL THEN
          PERFORM public.rpg_act(v_a.id, CASE WHEN coalesce(v_la.deals_damage, false) OR jsonb_typeof(v_la.makes_attacks) = 'array'
                                                THEN ARRAY[v_tg[1 + floor(random() * cardinality(v_tg))::integer]] ELSE v_tg END, NULL, v_la.id);
        END IF;
      END IF;
    END LOOP;
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
    v_state := v_next.recharge_state; v_txt := NULL;
    FOR v_a IN SELECT a.id, a.name, a.recharge_min FROM public.rpg_creature_actions a
                WHERE a.creature_id = v_next.creature_id AND a.recharge_min IS NOT NULL AND v_state ? a.id::text
                ORDER BY a.sort_order LOOP
      v_d6 := floor(random() * 6)::integer + 1;
      IF v_d6 >= v_a.recharge_min THEN v_state := v_state - v_a.id::text; END IF;
      v_txt := coalesce(v_txt || ', ', '') || v_a.name || ' ' || v_d6
               || CASE WHEN v_d6 >= v_a.recharge_min THEN ' (ready)' ELSE ' (not yet, needs ' || v_a.recharge_min || ')' END;
    END LOOP;
    IF v_txt IS NOT NULL THEN
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_round, 'recharge', 'info', v_next_id, v_next.name || ' rolls a six-sided die for each spent action: ' || v_txt || '.');
    END IF;
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
-- up and only uses actions that are ready (not spent). A ready lair action with a roll (Grasping Roots) is tried one
-- time in three. Then its main action: a ready move that lands an effect outright (Briar Roar) half the time,
-- otherwise Multiattack if ready, otherwise one other ready action with a roll. Every roll goes through rpg_act,
-- so the log reads the same as a hand-played turn. Legendary actions come from the die rolled as other turns end.
DECLARE
  v_s record; v_p record; v_pick record; v_targets uuid[]; v_t uuid; v_lines jsonb := '[]'::jsonb; v_r jsonb;
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
     WHERE a.creature_id = v_p.creature_id AND a.kind = 'lair' AND a.skill IS NOT NULL AND a.against IS NOT NULL
       AND NOT (v_p.recharge_state ? a.id::text) ORDER BY random() LIMIT 1;
    IF FOUND AND random() < 1.0 / 3 THEN
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' uses its lair: ' || v_pick.name || '.');
      v_r := public.rpg_act(v_p.id, v_targets, NULL, v_pick.id);
      v_lines := v_lines || (v_r->'results');
    END IF;
    SELECT * INTO v_pick FROM public.rpg_creature_actions a
     WHERE a.creature_id = v_p.creature_id AND a.kind = 'action' AND a.skill IS NOT NULL AND a.against IS NOT NULL
       AND a.effect->>'on' = 'land' AND NOT (v_p.recharge_state ? a.id::text) ORDER BY random() LIMIT 1;
    IF NOT (FOUND AND random() < 0.5) THEN
      SELECT * INTO v_pick FROM public.rpg_creature_actions a
       WHERE a.creature_id = v_p.creature_id AND a.kind = 'action' AND jsonb_typeof(a.makes_attacks) = 'array' AND jsonb_array_length(a.makes_attacks) > 0
         AND NOT (v_p.recharge_state ? a.id::text) ORDER BY a.sort_order LIMIT 1;
      IF NOT FOUND THEN
        SELECT * INTO v_pick FROM public.rpg_creature_actions a
         WHERE a.creature_id = v_p.creature_id AND a.kind = 'action' AND a.skill IS NOT NULL AND a.against IS NOT NULL
           AND NOT (v_p.recharge_state ? a.id::text) ORDER BY random() LIMIT 1;
      END IF;
    END IF;
    IF FOUND THEN
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' chooses ' || v_pick.name || '.');
      v_t := v_targets[1 + floor(random() * cardinality(v_targets))::integer];
      v_r := public.rpg_act(v_p.id, CASE WHEN coalesce(v_pick.deals_damage, false) AND NOT (jsonb_typeof(v_pick.makes_attacks) = 'array') THEN ARRAY[v_t] ELSE v_targets END, NULL, v_pick.id);
      v_lines := v_lines || (v_r->'results');
    ELSE
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' has nothing ready this turn.');
    END IF;
  END IF;
  PERFORM public.rpg_session_next_turn(p_session_id);
  RETURN jsonb_build_object('kind', 'auto', 'results', v_lines);
END;
$function$;

DO $do$
BEGIN
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('rpg_roll', 'rpg_act', 'rpg_session_next_turn', 'rpg_session_auto_turn')) <> 4 THEN RAISE EXCEPTION 'overloads appeared'; END IF;
  IF NOT (SELECT bool_and(has_function_privilege('authenticated', p.oid, 'EXECUTE')) FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'rpg\_%' AND p.prorettype <> 'trigger'::regtype AND p.proname <> 'rpg_manual_page_sync') THEN
    RAISE EXCEPTION 'an rpg_ function lost its grant';
  END IF;
  IF EXISTS (SELECT 1 FROM public.rpg_creature_actions WHERE kind <> 'trait' AND recharge_min IS NULL) THEN RAISE EXCEPTION 'an action has no cooldown'; END IF;
END $do$;
