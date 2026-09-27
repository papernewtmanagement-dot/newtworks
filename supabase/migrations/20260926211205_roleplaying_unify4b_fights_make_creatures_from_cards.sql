-- A creature made for one fight is a character kept for that fight only, and hidden from the players' lists.
ALTER TABLE public.rpg_characters ADD COLUMN IF NOT EXISTS session_id uuid REFERENCES public.rpg_sessions(id) ON DELETE CASCADE;
COMMENT ON COLUMN public.rpg_characters.session_id IS 'Set on a creature made from its card for one fight (rpg_session_add). Such a character is left off the character lists and the fight''s Add list.';
CREATE INDEX IF NOT EXISTS rpg_characters_session_id_idx ON public.rpg_characters (session_id) WHERE session_id IS NOT NULL;
-- Everyone in a fight has a sheet: a character, or a creature made from its card (creature_id then names the card).
ALTER TABLE public.rpg_session_participants DROP CONSTRAINT IF EXISTS rpg_session_participants_check;

CREATE OR REPLACE FUNCTION public.rpg_participant_values(p_participant_id uuid, p_keys text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One fighter's numbers in one read: {key: value} for the keys asked for (every stat on their sheet when none are
-- named), each plus what an effect on them adds. Everyone in a fight has a sheet, a creature made from its card
-- included, so everyone is read the same way (rpg_sheet_values). A stat the fighter does not have is left out.
-- A Bramblemaw Dug in (Sink Into Soil, bonus {"EE": 4}): EE 8 + 4 = 12. Karen: EE 5, AG 1.
DECLARE v_p record; v_vals jsonb; v_bonus jsonb; v_out jsonb := '{}'::jsonb; v_key text;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  IF v_p.character_id IS NULL THEN RAISE EXCEPTION '% has no sheet', v_p.name; END IF;
  v_vals := public.rpg_sheet_values(v_p.character_id)->'values';
  SELECT coalesce(jsonb_object_agg(b.key, b.total), '{}'::jsonb) INTO v_bonus
    FROM (SELECT x.key, sum(x.value::numeric) AS total
            FROM jsonb_array_elements(v_p.effects) e, jsonb_each_text(e->'bonus') x
           WHERE jsonb_typeof(e->'bonus') = 'object' GROUP BY x.key) b;
  FOR v_key IN SELECT k FROM jsonb_object_keys(v_vals) k
                WHERE (p_keys IS NULL OR k = ANY (p_keys))
                  AND NOT EXISTS (SELECT 1 FROM public.rpg_stat_definitions d WHERE d.key = k AND d.side = 'evil') LOOP
    v_out := v_out || jsonb_build_object(v_key, (v_vals->>v_key)::numeric + coalesce((v_bonus->>v_key)::numeric, 0));
  END LOOP;
  RETURN v_out;
END;
$function$;
REVOKE ALL ON FUNCTION public.rpg_participant_values(uuid, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpg_participant_values(uuid, text[]) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.rpg_participant_value(p_participant_id uuid, p_stat_key text)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One fighter's value for one stat, from rpg_participant_values (their sheet plus what an effect on them adds).
-- Karen: EE → 5, AG → 1. A Bramblemaw: EE → 8, Claw → 10, IG → 8, PV → 149, PEN → 45. NULL when they do not have it.
SELECT (public.rpg_participant_values(p_participant_id, ARRAY[p_stat_key])->>p_stat_key)::numeric;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_participant_vitality(p_participant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A fighter's vitality as {max, left, damage}: Physical Vitality from their sheet less the damage carried on their
-- character (Karen 41 with 10 damage → 31 left; a Bramblemaw 149 with 30 → 119). Left never shows below 0.
DECLARE v_p record; v_calc jsonb; v_max integer; v_dmg integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  IF v_p.character_id IS NULL THEN RAISE EXCEPTION '% has no sheet', v_p.name; END IF;
  v_calc := public.rpg_sheet_values(v_p.character_id);
  v_max := (v_calc->>'vitality_max')::numeric::integer;
  v_dmg := (v_calc->>'vitality_damage')::integer;
  RETURN jsonb_build_object('max', v_max, 'left', greatest(v_max - v_dmg, 0), 'damage', v_dmg);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_participant_energy(p_participant_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Both pools for one fighter, from one read of their numbers (PEN/PER/SEN/SER): max and regain from the rules,
-- left = max minus what has been spent (energy_used_*). A Bramblemaw: physical 45, regain 7; spiritual 30, regain 4.
-- A fresh fight starts full.
WITH v AS MATERIALIZED (
  SELECT p.energy_used_physical AS used_p, p.energy_used_spiritual AS used_s,
         public.rpg_participant_values(p.id, ARRAY['PEN', 'PER', 'SEN', 'SER']) AS j
    FROM public.rpg_session_participants p WHERE p.id = p_participant_id)
SELECT jsonb_build_object(
  'physical', jsonb_build_object('max', coalesce((j->>'PEN')::numeric, 0)::integer,
                                 'left', greatest(coalesce((j->>'PEN')::numeric, 0)::integer - used_p, 0),
                                 'regain', coalesce((j->>'PER')::numeric, 0)::integer),
  'spiritual', jsonb_build_object('max', coalesce((j->>'SEN')::numeric, 0)::integer,
                                  'left', greatest(coalesce((j->>'SEN')::numeric, 0)::integer - used_s, 0),
                                  'regain', coalesce((j->>'SER')::numeric, 0)::integer))
  FROM v;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_action_score(p_actor_id uuid, p_action_id uuid, p_target_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- How much one action at one target is worth, in damage points, so the site can choose a creature's move:
-- chance to land × average damage (die minus Needed, over the hits), plus what its effect is worth on that target
-- (a hold or knockdown 25, a fright or trance 12; half that when a contest roll must land too; nothing if they
-- already have it or already cannot act), plus 15 when an average hit would finish them. The skill is the one the
-- action rolls, read from the creature's own sheet.
-- Claw 10 at Karen (Evade Enemy 5, can act → difficulty 10 → needs 50): 51% × 25 = 12.8, plus half a knockdown.
DECLARE
  v_a record; v_u record; v_t record; v_skill numeric; v_def numeric; v_diff numeric; v_needed numeric; v_p numeric; v_avg numeric;
  v_left integer; v_score numeric := 0; v_fx jsonb; v_can boolean;
BEGIN
  SELECT * INTO v_a FROM public.rpg_creature_actions WHERE id = p_action_id;
  IF NOT FOUND THEN RETURN 0; END IF;
  IF jsonb_typeof(v_a.makes_attacks) = 'array' AND jsonb_array_length(v_a.makes_attacks) = 1 AND coalesce((v_a.makes_attacks->0->>'count')::integer, 1) = 1 THEN
    SELECT * INTO v_u FROM public.rpg_creature_actions WHERE creature_id = v_a.creature_id AND name = v_a.makes_attacks->0->>'action' LIMIT 1;
    IF NOT FOUND THEN RETURN 0; END IF;
  ELSE
    v_u := v_a;
  END IF;
  IF v_u.skill_key IS NULL OR v_u.against IS NULL THEN RETURN 0; END IF;
  SELECT * INTO v_t FROM public.rpg_session_participants WHERE id = p_target_id;
  IF NOT FOUND THEN RETURN 0; END IF;
  v_left := (public.rpg_participant_vitality(p_target_id)->>'left')::integer;
  IF v_left <= 0 THEN RETURN 0; END IF;
  v_skill := public.rpg_participant_value(p_actor_id, v_u.skill_key);
  IF v_skill IS NULL THEN RETURN 0; END IF;
  v_can := public.rpg_participant_can_act(p_target_id);
  v_def := coalesce(public.rpg_participant_value(p_target_id, v_u.against), 0);
  v_diff := public.rpg_difficulty(v_def, v_can);
  v_needed := (public.rpg_needed(v_skill, v_diff)->>'needed')::numeric;
  v_p := greatest(least((101 - v_needed) / 100, 1), 0);
  IF coalesce(v_u.deals_damage, false) THEN
    v_avg := greatest((100 - v_needed) / 2, 1);
    v_score := v_p * v_avg + CASE WHEN v_avg >= v_left THEN 15 ELSE 0 END;
  END IF;
  v_fx := v_u.effect;
  IF v_fx IS NOT NULL AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_t.effects) e WHERE e->>'name' = v_fx->'apply'->>'name') THEN
    IF coalesce((v_fx->'apply'->>'cannot_act')::boolean, false) THEN
      IF v_can THEN v_score := v_score + v_p * 25 * CASE WHEN v_fx ? 'contest' THEN 0.5 ELSE 1 END; END IF;
    ELSE
      v_score := v_score + v_p * 12 * CASE WHEN v_fx ? 'contest' THEN 0.5 ELSE 1 END;
    END IF;
  END IF;
  RETURN round(v_score, 1);
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
-- A Claw that hit for 50 so far with an extra roll of 22 → 22 more damage, 72 in all. Only the game master enters a
-- creature's.
DECLARE v_ev record; v_p record; v_s record; v_x jsonb; v_vit jsonb; v_dmg integer := 0; v_text text; v_tail text := '';
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_ev FROM public.rpg_events WHERE roll_id = p_roll_id ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'that roll is not in a fight'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = v_ev.actor_id;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_ev.session_id FOR UPDATE;
  IF v_s.status <> 'active' THEN RAISE EXCEPTION 'that fight is not on'; END IF;
  IF NOT public.family_is_parent() AND (v_p.creature_id IS NOT NULL OR v_s.current_participant_id IS DISTINCT FROM v_p.id) THEN
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

CREATE OR REPLACE FUNCTION public.rpg_character_list()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The Characters tab list. A creature made for a fight (session_id set) is not on it.
SELECT public.require_login('family');
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'kid_id', c.kid_id, 'kid_name', k.name,
           'is_npc', c.is_npc, 'color', c.color, 'vitality_damage', c.vitality_damage, 'is_active', c.is_active,
           'created_at', c.created_at) ORDER BY c.is_npc, k.sort_order NULLS LAST, c.created_at), '[]'::jsonb)
  FROM public.rpg_characters c
  LEFT JOIN public.family_kids k ON k.id = c.kid_id
  WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.session_id IS NULL AND (SELECT public.rpg_can_play());
$function$;
CREATE OR REPLACE FUNCTION public.rpg_act(p_actor_id uuid, p_target_ids uuid[] DEFAULT NULL::uuid[], p_stat_key text DEFAULT NULL::text, p_action_id uuid DEFAULT NULL::uuid, p_against text DEFAULT NULL::text, p_difficulty numeric DEFAULT NULL::numeric, p_roll integer DEFAULT NULL::integer, p_effect text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One move in a fight, by the one whose turn it is. Every roll goes through rpg_roll, from the roller's own sheet.
--   REST / DEFEND (p_stat_key) take the whole turn: Rest gives one more regain; Defend puts "Defending" on you until
--   your next turn so rolls against you face your skill × 3 (rpg_difficulty).
--   Anyone rolls from their own sheet (p_stat_key): a weapon skill at one target is an attack; any stat at targets
--   with p_against rolls against that stat of theirs; with no target it is a check. A creature also uses the actions
--   on its card, each rolling one of its own skills by skill_key (the Bramblemaw's Claw rolls its sheet's Claw 10).
--   A creature is a character made from its card, so its sheet, its Integrity and its energy work like yours.
--   Attacks and actions cost beats of the turn and energy (energy_cost of that energy_type); a move you cannot pay
--   for is refused.
--   An attack runs three gates (rule card "Land, Block, Hit"). Land: the skill against the target's evade × 2
--   (rpg_difficulty; evade lowered by rpg_participant_burden). Under the still-target line is a Miss, above it Evaded.
--   Block: someone holding a shield or weapon blocks with Block + the item's block, × 2; a spiritual attack that
--   lands an effect is blocked by the Shield of Faith. Fail = Blocked; the blocking item takes the blow's damage
--   (rpg_item_damage) and the weapon a fifth of it. Hit: rpg_damage minus what worn armor absorbs (the armor takes
--   that; the weapon a fifth); what is left must clear the target's Integrity. A landed effect goes on the target as
--   the card says (Briar Roar → Frightened; a Claw hit → Strength contest → Knocked down). Legendary actions may be
--   used on other turns by the game master or the rules engine (rpg.engine). A check a rule demands (p_effect) comes
--   before an attack. p_roll is a die rolled by hand: a manual critical waits for rpg_act_extra.
DECLARE
  v_gm boolean := public.family_is_parent() OR current_setting('rpg.engine', true) = 'on';
  v_actor record; v_s record; v_act record; v_use record; v_t record; v_item record;
  v_targets uuid[] := coalesce(p_target_ids, '{}'::uuid[]);
  v_kind text; v_key text; v_label text; v_against text; v_against_name text;
  v_damage_ok boolean := false; v_is_attack boolean := false; v_stat_name text; v_spirit_fx boolean := false;
  v_tid uuid; v_cid uuid; v_def numeric; v_diff numeric; v_diff_still numeric; v_roll jsonb; v_first jsonb; v_extras integer[]; v_i integer;
  v_dmg integer; v_net integer; v_vit jsonb; v_text text; v_needs integer; v_results jsonb := '[]'::jsonb; v_levelup text;
  v_eff jsonb; v_fx jsonb; v_out jsonb; v_pending boolean; v_tail text; v_who text; v_xtext text;
  v_croll jsonb; v_cdiff numeric; v_per integer := public.rpg_setting('beats_per_turn')::integer;
  v_plan jsonb := '[]'::jsonb; v_step jsonb; v_e jsonb; v_n integer; v_beats integer := 0;
  v_ecost integer := 0; v_etype text := 'physical'; v_energy jsonb; v_defending boolean;
  v_blk numeric; v_blocker uuid; v_blocker_name text; v_broll jsonb; v_blocked boolean; v_absorb integer; v_wear jsonb; v_weapon uuid; v_integrity integer; v_bounced boolean;
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
  IF NOT v_gm AND v_actor.creature_id IS NOT NULL THEN RAISE EXCEPTION 'the game master rolls for %', v_actor.name; END IF;
  IF v_actor.character_id IS NULL THEN RAISE EXCEPTION '% has no sheet', v_actor.name; END IF;
  IF NOT v_actor.can_act THEN RAISE EXCEPTION '% cannot act%', v_actor.name, coalesce(': ' || v_actor.status_note, ''); END IF;
  IF (public.rpg_participant_vitality(p_actor_id)->>'left')::integer <= 0 THEN RAISE EXCEPTION '% is down', v_actor.name; END IF;
  SELECT e->>'name' INTO v_who FROM jsonb_array_elements(v_actor.effects) e WHERE coalesce((e->>'cannot_act')::boolean, false) LIMIT 1;
  IF v_who IS NOT NULL AND p_effect IS DISTINCT FROM v_who THEN RAISE EXCEPTION '% is % and cannot act', v_actor.name, v_who; END IF;
  IF p_actor_id = ANY (v_targets) THEN RAISE EXCEPTION 'choose someone else to aim at'; END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_targets) t(id)
              WHERE NOT EXISTS (SELECT 1 FROM public.rpg_session_participants p WHERE p.id = t.id AND p.session_id = v_s.id)) THEN
    RAISE EXCEPTION 'every target must be in this fight';
  END IF;
  v_energy := public.rpg_participant_energy(p_actor_id);

  -- Rest and Defend: the whole turn.
  IF p_stat_key IN ('REST', 'DEFEND') THEN
    IF v_s.current_participant_id IS DISTINCT FROM p_actor_id THEN RAISE EXCEPTION 'it is not %''s turn', v_actor.name; END IF;
    IF v_s.turn_beats > 0 THEN RAISE EXCEPTION '% has already used part of this turn', v_actor.name; END IF;
    IF p_stat_key = 'REST' THEN
      UPDATE public.rpg_session_participants SET energy_used_physical = greatest(energy_used_physical - (v_energy->'physical'->>'regain')::integer, 0),
             energy_used_spiritual = greatest(energy_used_spiritual - (v_energy->'spiritual'->>'regain')::integer, 0) WHERE id = p_actor_id;
      v_text := v_actor.name || ' rests and regains ' || (v_energy->'physical'->>'regain') || ' physical and ' || (v_energy->'spiritual'->>'regain') || ' spiritual energy.';
    ELSE
      PERFORM public.rpg_participant_apply_effect(p_actor_id, '{"name": "Defending", "cannot_act": false, "clear": "turn_start", "defend": true}'::jsonb, 'Defend', v_s.round);
      v_text := v_actor.name || ' defends: until ' || CASE WHEN v_actor.creature_id IS NULL THEN 'their' ELSE 'its' END || ' next turn, rolls against ' || CASE WHEN v_actor.creature_id IS NULL THEN 'them' ELSE 'it' END || ' face evade × ' || trim_scale(public.rpg_setting('defend_multiplier')) || '.';
    END IF;
    UPDATE public.rpg_sessions SET turn_beats = v_per, updated_at = now() WHERE id = v_s.id;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, v_s.id, v_s.round, 'action', 'info', p_actor_id, v_text);
    RETURN jsonb_build_object('kind', lower(p_stat_key), 'label', initcap(lower(p_stat_key)), 'results', jsonb_build_array(jsonb_build_object('outcome', 'info', 'text', v_text)));
  END IF;

  IF p_effect IS NOT NULL THEN
    SELECT e INTO v_eff FROM jsonb_array_elements(v_actor.effects) e WHERE e->>'name' = p_effect AND e->>'clear' = 'check';
    IF v_eff IS NULL THEN RAISE EXCEPTION '% is not % right now', v_actor.name, p_effect; END IF;
    IF (v_eff->>'checked_round')::integer = v_s.round THEN RAISE EXCEPTION '% already tried this round', v_actor.name; END IF;
    v_kind := 'check'; v_key := v_eff->>'check_stat'; v_targets := '{}';
    SELECT name INTO v_label FROM public.rpg_stat_definitions WHERE key = v_key;
    v_diff := (v_eff->>'check_difficulty')::numeric;
  ELSIF p_action_id IS NULL THEN
    -- Anyone rolling from their own sheet.
    SELECT name, is_attack, beats, energy_cost, energy_type INTO v_stat_name, v_is_attack, v_beats, v_ecost, v_etype FROM public.rpg_stat_definitions WHERE key = p_stat_key;
    IF NOT FOUND THEN RAISE EXCEPTION 'choose a skill'; END IF;
    v_key := p_stat_key; v_label := v_stat_name;
    IF cardinality(v_targets) > 0 AND p_against IS NULL THEN
      IF NOT v_is_attack THEN RAISE EXCEPTION 'choose a weapon skill to attack with'; END IF;
      IF cardinality(v_targets) > 1 THEN RAISE EXCEPTION 'attack one target at a time'; END IF;
      IF v_s.turn_beats + v_beats > v_per THEN RAISE EXCEPTION '% has % of % beats left this turn and % takes %', v_actor.name, v_per - v_s.turn_beats, v_per, v_stat_name, v_beats; END IF;
      IF (v_energy->v_etype->>'left')::integer < v_ecost THEN RAISE EXCEPTION '% has % % energy left and % costs %', v_actor.name, v_energy->v_etype->>'left', v_etype, v_stat_name, v_ecost; END IF;
      SELECT e->>'name' INTO v_who FROM jsonb_array_elements(v_actor.effects) e
       WHERE e->>'clear' = 'check' AND (e->>'checked_round')::integer IS DISTINCT FROM v_s.round LIMIT 1;
      IF v_who IS NOT NULL THEN RAISE EXCEPTION '% must shake off % first', v_actor.name, v_who; END IF;
      v_kind := 'attack'; v_against := 'EE'; v_damage_ok := true;
      SELECT id INTO v_weapon FROM public.rpg_items WHERE character_id = v_actor.character_id AND equipped AND NOT worn AND weapon_key = p_stat_key AND integrity_damage < integrity ORDER BY sort_order LIMIT 1;
    ELSIF cardinality(v_targets) > 0 THEN
      v_kind := 'check'; v_beats := 0; v_ecost := 0; v_against := p_against;
    ELSE
      v_kind := 'check'; v_beats := 0; v_ecost := 0;
      v_diff := greatest(coalesce(p_difficulty, public.rpg_setting('default_difficulty')), 0);
    END IF;
  ELSE
    SELECT * INTO v_act FROM public.rpg_creature_actions WHERE id = p_action_id AND creature_id = v_actor.creature_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'that action is not on this creature''s card'; END IF;
    IF v_act.kind = 'trait' THEN RAISE EXCEPTION '% is a trait, not an action', v_act.name; END IF;
    IF v_act.kind = 'legendary' AND v_actor.legendary_left < v_act.legendary_cost THEN
      RAISE EXCEPTION '% has % legendary actions left and % costs %', v_actor.name, v_actor.legendary_left, v_act.name, v_act.legendary_cost;
    END IF;
    IF NOT public.rpg_action_ready(p_actor_id, v_act.id) THEN
      RAISE EXCEPTION '% has % % energy left and % costs %', v_actor.name, v_energy->v_act.energy_type->>'left', v_act.energy_type, v_act.name, v_act.energy_cost;
    END IF;
    IF (SELECT coalesce(sum(greatest(coalesce((e->>'count')::integer, 1), 1)), 0) FROM jsonb_array_elements(coalesce(v_act.makes_attacks, '[]'::jsonb)) e) > 1 THEN
      RAISE EXCEPTION '% makes one attack a turn; % is not used. Pick one of its attacks', v_actor.name, v_act.name;
    END IF;
    IF v_act.kind IN ('action', 'bonus_action') AND v_s.current_participant_id = p_actor_id THEN
      IF v_s.turn_beats + v_act.beats > v_per THEN
        RAISE EXCEPTION '% has % of % beats left this turn and % takes %', v_actor.name, v_per - v_s.turn_beats, v_per, v_act.name, v_act.beats;
      END IF;
      v_beats := v_act.beats;
    END IF;
    v_ecost := v_act.energy_cost; v_etype := v_act.energy_type;
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
    ELSIF v_act.skill_key IS NOT NULL THEN
      IF cardinality(v_targets) = 0 THEN RAISE EXCEPTION 'choose who % is aimed at', v_act.name; END IF;
      FOREACH v_tid IN ARRAY v_targets LOOP v_plan := v_plan || jsonb_build_object('a', v_act.id, 't', v_tid); END LOOP;
    END IF;
  END IF;
  IF v_kind <> 'action' THEN
    FOREACH v_tid IN ARRAY v_targets LOOP v_plan := v_plan || jsonb_build_object('t', v_tid); END LOOP;
    IF cardinality(v_targets) > 0 THEN
      SELECT name INTO v_against_name FROM public.rpg_stat_definitions WHERE key = v_against;
      IF NOT FOUND THEN RAISE EXCEPTION 'unknown stat %', v_against; END IF;
    END IF;
  END IF;

  IF v_kind = 'action' AND jsonb_array_length(v_plan) = 0 THEN
    IF v_act.effect->>'on' = 'self' THEN
      PERFORM public.rpg_participant_apply_effect(p_actor_id, v_act.effect->'apply', v_act.name, v_s.round);
    END IF;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, v_s.id, v_s.round, 'action', 'info', p_actor_id, v_actor.name || ' uses ' || v_act.name || '.'
            || CASE WHEN v_act.effect->>'on' = 'self' THEN ' It is ' || (v_act.effect->'apply'->>'name') || '.' ELSE '' END);
  ELSIF cardinality(v_targets) = 0 THEN
    v_roll := public.rpg_roll(v_actor.character_id, v_key, v_diff, v_label, NULL, v_s.id, p_actor_id, NULL, p_roll);
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
          UPDATE public.rpg_sessions SET turn_beats = v_per WHERE id = v_s.id;
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
      IF v_kind = 'action' AND jsonb_array_length(v_plan) > 1 AND (public.rpg_participant_vitality(v_tid)->>'left')::integer <= 0 THEN
        SELECT p.id INTO v_tid FROM public.rpg_session_participants p
         WHERE p.id = ANY (v_targets) AND (public.rpg_participant_vitality(p.id)->>'left')::integer > 0 ORDER BY random() LIMIT 1;
        EXIT WHEN v_tid IS NULL;
      END IF;
      IF v_kind = 'action' THEN
        SELECT * INTO v_use FROM public.rpg_creature_actions WHERE id = (v_step->>'a')::uuid;
        IF v_use.skill_key IS NULL THEN RAISE EXCEPTION '% has no roll on the card', v_use.name; END IF;
        v_key := v_use.skill_key; v_against := v_use.against; v_damage_ok := coalesce(v_use.deals_damage, false); v_fx := v_use.effect;
        v_spirit_fx := v_fx IS NOT NULL AND v_use.energy_type = 'spiritual';
        SELECT name INTO v_against_name FROM public.rpg_stat_definitions WHERE key = v_against;
        IF NOT FOUND THEN RAISE EXCEPTION 'unknown stat %', v_against; END IF;
      END IF;
      SELECT * INTO v_t FROM public.rpg_session_participants WHERE id = v_tid;
      v_defending := EXISTS (SELECT 1 FROM jsonb_array_elements(v_t.effects) e WHERE coalesce((e->>'defend')::boolean, false));
      -- Gate 1: land. Evade lowered by burden.
      v_def := greatest(coalesce(public.rpg_participant_value(v_tid, v_against), 0)
                        - CASE WHEN v_against IN ('EE', 'BGP') THEN public.rpg_participant_burden(v_tid, CASE WHEN v_against = 'BGP' THEN 'spiritual' ELSE 'physical' END) ELSE 0 END, 0);
      v_diff := public.rpg_difficulty(v_def, public.rpg_participant_can_act(v_tid), v_defending);
      v_diff_still := public.rpg_difficulty(v_def, false);
      v_roll := public.rpg_roll(v_actor.character_id, v_key, v_diff, v_label, NULL, v_s.id, p_actor_id, NULL,
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
      v_needs := ceil((v_first->>'needed')::numeric)::integer;
      v_dmg := CASE WHEN v_damage_ok THEN public.rpg_damage((v_first->>'roll_id')::uuid) ELSE 0 END;
      v_tail := ''; v_blocked := false; v_net := v_dmg; v_absorb := 0;
      -- Gate 2: block. Someone holding a shield or weapon; the Shield of Faith against a spiritual effect.
      IF v_first->>'result' <> '' AND v_t.character_id IS NOT NULL AND (v_damage_ok OR v_spirit_fx) THEN
        v_blk := NULL; v_blocker := NULL; v_blocker_name := NULL;
        IF v_damage_ok THEN
          SELECT i.id, i.name, i.block INTO v_blocker, v_blocker_name, v_blk FROM public.rpg_items i
           WHERE i.character_id = v_t.character_id AND i.equipped AND NOT i.worn AND i.integrity_damage < i.integrity
           ORDER BY i.block DESC, i.sort_order LIMIT 1;
          IF v_blocker IS NOT NULL THEN v_blk := coalesce(public.rpg_participant_value(v_tid, 'BLK'), 0) + coalesce(v_blk, 0); END IF;
        ELSE
          v_blk := public.rpg_participant_value(v_tid, 'SF'); v_blocker_name := 'Shield of Faith';
        END IF;
        IF v_blk IS NOT NULL THEN
          v_broll := public.rpg_roll(v_actor.character_id, v_key, public.rpg_difficulty(v_blk, public.rpg_participant_can_act(v_tid), v_defending), v_label || ' (block)', NULL, v_s.id, p_actor_id, NULL);
          IF v_broll->>'result' = '' THEN
            v_blocked := true; v_net := 0;
            v_tail := ' Blocked by ' || CASE WHEN v_blocker IS NOT NULL THEN v_t.name || '''s ' || v_blocker_name ELSE v_t.name || '''s Shield of Faith' END
                      || ' (rolled ' || (v_broll->>'roll') || ', needs ' || ceil((v_broll->>'needed')::numeric) || ').';
            IF v_blocker IS NOT NULL AND v_dmg > 0 THEN
              v_wear := public.rpg_item_damage(v_blocker, v_dmg);
              v_tail := v_tail || ' The ' || v_blocker_name || ' takes ' || v_dmg || CASE WHEN (v_wear->>'broke')::boolean THEN ' and breaks.' ELSE ', ' || (v_wear->>'left') || ' left.' END;
              IF v_weapon IS NOT NULL THEN PERFORM public.rpg_item_damage(v_weapon, ceil(v_dmg / 5.0)::integer); END IF;
            END IF;
          ELSE
            v_tail := ' Past the block (rolled ' || (v_broll->>'roll') || ', needs ' || ceil((v_broll->>'needed')::numeric) || ').';
          END IF;
        END IF;
      END IF;
      -- Gate 3: hit. Armor absorbs and takes what it absorbed; the weapon a fifth.
      IF v_dmg > 0 AND NOT v_blocked AND v_t.character_id IS NOT NULL THEN
        FOR v_item IN SELECT i.id, i.name, i.absorb FROM public.rpg_items i
                       WHERE i.character_id = v_t.character_id AND i.equipped AND i.worn AND i.absorb > 0 AND i.integrity_damage < i.integrity ORDER BY i.absorb DESC LOOP
          EXIT WHEN v_net <= 0;
          v_absorb := least(v_item.absorb, v_net);
          v_net := v_net - v_absorb;
          v_wear := public.rpg_item_damage(v_item.id, v_absorb);
          v_tail := v_tail || ' ' || v_item.name || ' absorbs ' || v_absorb || CASE WHEN (v_wear->>'broke')::boolean THEN ' and breaks.' ELSE '.' END;
          IF v_weapon IS NOT NULL THEN PERFORM public.rpg_item_damage(v_weapon, ceil(v_absorb / 5.0)::integer); END IF;
        END LOOP;
      END IF;
      -- Integrity: what is left after armor must clear the target's Integrity (Toughness ÷ 5) or it does nothing.
      v_bounced := false;
      IF v_net > 0 AND NOT v_blocked THEN
        v_integrity := coalesce(public.rpg_participant_value(v_tid, 'IG'), 0)::integer;
        IF v_net <= v_integrity THEN
          v_bounced := true;
          v_tail := v_tail || ' ' || v_net || ' does not get through ' || v_t.name || '''s Integrity of ' || v_integrity || '.';
          v_net := 0;
        END IF;
      END IF;
      IF v_net > 0 THEN v_vit := public.rpg_session_adjust_vitality(v_tid, v_net);
      ELSE v_vit := public.rpg_participant_vitality(v_tid); END IF;
      v_out := CASE WHEN v_blocked THEN jsonb_build_object('key', 'blocked', 'label', 'Blocked')
                    WHEN v_bounced THEN jsonb_build_object('key', 'bounced', 'label', 'Bounced off')
                    ELSE public.rpg_outcome((v_first->>'roll')::integer, (v_first->>'needed')::numeric, (v_first->>'critical')::numeric, v_damage_ok, v_net,
                                            (public.rpg_needed(coalesce(v_first->>'skill', '0')::numeric, v_diff_still)->>'needed')::numeric) END;
      v_levelup := CASE WHEN (v_roll->>'level_after')::integer > (v_first->>'level_before')::integer
                        THEN ' ' || v_actor.name || '''s ' || coalesce(v_first->>'stat_name', v_label) || ' goes up to ' || (v_roll->>'level_after') || '!' ELSE '' END;
      -- Built with IF, not CASE: PL/pgSQL plans every CASE branch, and v_use is only assigned for a card action.
      IF v_kind = 'attack' THEN
        v_who := v_actor.name || ' attacks ' || v_t.name || ' with ' || v_label;
      ELSIF v_kind = 'action' THEN
        v_who := v_actor.name || '''s ' || v_use.name || CASE WHEN v_use.id <> v_act.id THEN ' (' || v_act.name || ')' ELSE '' END
                 || ' at ' || v_t.name || CASE WHEN v_damage_ok THEN '' ELSE ' (' || v_against_name || ')' END;
      ELSE
        v_who := v_actor.name || ' rolls ' || v_label || ' against ' || v_t.name || '''s ' || v_against_name;
      END IF;
      -- Players see a creature's health as a bar only, so the log gives a number left only for characters.
      v_tail := v_tail || CASE WHEN v_net > 0 AND (v_vit->>'left')::integer <= 0 THEN ' ' || v_t.name || ' is down.'
                               WHEN v_net > 0 AND v_t.creature_id IS NULL THEN ' ' || v_t.name || ' has ' || (v_vit->>'left') || ' left.'
                               ELSE '' END;
      IF v_kind = 'action' AND v_fx IS NOT NULL AND v_first->>'result' <> '' AND NOT v_blocked AND NOT v_bounced AND (v_vit->>'left')::integer > 0 THEN
        IF v_fx->>'on' = 'land' AND NOT v_damage_ok THEN
          PERFORM public.rpg_participant_apply_effect(v_tid, v_fx->'apply', v_use.name, v_s.round);
          v_tail := v_tail || ' ' || v_t.name || ' is ' || (v_fx->'apply'->>'name') || '.';
        ELSIF v_fx->>'on' = 'hit' AND v_net > 0 AND v_fx ? 'contest' THEN
          v_cdiff := public.rpg_difficulty(coalesce(public.rpg_participant_value(v_tid, v_fx->'contest'->>'against'), 0), public.rpg_participant_can_act(v_tid), v_defending);
          v_croll := public.rpg_roll(v_actor.character_id, v_fx->'contest'->>'skill_key', v_cdiff, v_use.name || ' (' || (v_fx->'apply'->>'name') || ')', NULL, v_s.id, p_actor_id, NULL);
          IF v_croll->>'result' <> '' THEN
            PERFORM public.rpg_participant_apply_effect(v_tid, v_fx->'apply', v_use.name, v_s.round);
            v_tail := v_tail || ' ' || v_t.name || ' is ' || (v_fx->'apply'->>'name');
          ELSE
            v_tail := v_tail || ' ' || v_t.name || ' stays up';
          END IF;
          v_tail := v_tail || ' (' || (v_croll->>'stat_name') || ' ' || trim_scale((v_croll->>'skill')::numeric) || ' against ' || trim_scale(v_cdiff)
                    || ': rolled ' || (v_croll->>'roll') || ', needs ' || ceil((v_croll->>'needed')::numeric) || ').';
        END IF;
      END IF;
      v_xtext := CASE WHEN cardinality(v_extras) > 0 THEN ' Extra roll' || CASE WHEN cardinality(v_extras) > 1 THEN 's ' ELSE ' ' END || array_to_string(v_extras, ' and ') || '.' ELSE '' END;
      v_text := (v_out->>'label') || CASE WHEN v_damage_ok AND v_net > 0 THEN ' for ' || v_net || CASE WHEN v_pending THEN ' so far' ELSE '' END ELSE '' END
                || ': ' || v_who || '. Rolled ' || (v_first->>'roll') || ', needs ' || v_needs || '.' || v_xtext
                || CASE WHEN v_pending THEN ' Roll again and enter it.' ELSE '' END || v_tail || v_levelup;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, target_id, roll_id, damage, text)
      VALUES (v_s.agency_id, v_s.id, v_s.round, v_kind, v_out->>'key', p_actor_id, v_tid, (v_first->>'roll_id')::uuid, v_net, v_text);
      v_results := v_results || jsonb_build_array(jsonb_build_object('roll_id', v_first->'roll_id', 'target_id', v_tid, 'target_name', v_t.name,
                     'roll', v_first->'roll', 'needed', v_first->'needed', 'result', v_first->'result', 'outcome', v_out->>'key',
                     'extras', to_jsonb(v_extras), 'extra_pending', v_pending, 'difficulty', v_diff, 'damage', v_net,
                     'down', (v_vit->>'left')::integer <= 0, 'text', v_text));
    END LOOP;
  END IF;

  IF v_beats > 0 AND v_kind IN ('attack', 'action') THEN
    UPDATE public.rpg_sessions SET turn_beats = turn_beats + v_beats WHERE id = v_s.id;
  END IF;
  IF v_ecost > 0 AND v_kind IN ('attack', 'action') THEN
    IF v_etype = 'spiritual' THEN UPDATE public.rpg_session_participants SET energy_used_spiritual = energy_used_spiritual + v_ecost WHERE id = p_actor_id;
    ELSE UPDATE public.rpg_session_participants SET energy_used_physical = energy_used_physical + v_ecost WHERE id = p_actor_id; END IF;
  END IF;
  IF v_kind = 'action' THEN
    UPDATE public.rpg_session_participants
       SET legendary_left = legendary_left - CASE WHEN v_act.kind = 'legendary' THEN v_act.legendary_cost ELSE 0 END
     WHERE id = p_actor_id;
  END IF;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_s.id;
  RETURN jsonb_build_object('kind', v_kind, 'label', v_label, 'results', v_results);
END;
$function$;
CREATE OR REPLACE FUNCTION public.rpg_session_add(p_session_id uuid, p_character_id uuid DEFAULT NULL::uuid, p_creature_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Adds one character, or one creature made fresh from its card, to a fight at its Agility place: ahead of the first
-- one in line with lower Agility, so higher Agility acts first and a tie goes after whoever joined first. The game
-- master's own moves stay. A creature is made the way any character is made (rpg_new_character from its card, as a
-- non-player character), kept for this fight only (session_id) and left off the players' lists. So two Ashwing
-- Harriers are two different rolls (Physical Vitality 40 to 50), while a boss card like the Bramblemaw comes out the
-- same every time. The Bramblemaw (Agility 7) lands ahead of Karen (Agility 1). A second one is named "Bramblemaw 2".
DECLARE v_s record; v_name text; v_card text; v_leg integer := 0; v_n integer; v_id uuid; v_char uuid := p_character_id; v_ag numeric; v_pos integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master adds to a fight'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  IF (p_character_id IS NULL) = (p_creature_id IS NULL) THEN RAISE EXCEPTION 'add one character or one creature'; END IF;
  IF p_character_id IS NOT NULL THEN
    SELECT name INTO v_name FROM public.rpg_characters WHERE id = p_character_id AND is_active AND session_id IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'character not found'; END IF;
    IF EXISTS (SELECT 1 FROM public.rpg_session_participants WHERE session_id = p_session_id AND character_id = p_character_id) THEN
      RAISE EXCEPTION '% is already in this fight', v_name;
    END IF;
  ELSE
    SELECT name, key, legendary_per_round INTO v_name, v_card, v_leg FROM public.rpg_creatures WHERE id = p_creature_id AND is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'creature not found'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.rpg_creature_actions WHERE creature_id = p_creature_id AND kind <> 'trait') THEN
      RAISE EXCEPTION '% has nothing on its card to fight with', v_name;
    END IF;
    SELECT count(*) INTO v_n FROM public.rpg_session_participants WHERE session_id = p_session_id AND creature_id = p_creature_id;
    IF v_n > 0 THEN v_name := v_name || ' ' || (v_n + 1); END IF;
    v_char := public.rpg_new_character(v_name, NULL, true, v_card);
    UPDATE public.rpg_characters SET session_id = p_session_id WHERE id = v_char;
  END IF;
  INSERT INTO public.rpg_session_participants (agency_id, session_id, character_id, creature_id, name, legendary_left)
  VALUES (v_s.agency_id, p_session_id, v_char, p_creature_id, v_name, coalesce(v_leg, 0))
  RETURNING id INTO v_id;
  v_ag := coalesce(public.rpg_participant_value(v_id, 'AG'), 0);
  SELECT min(p.turn_order) INTO v_pos FROM public.rpg_session_participants p
   WHERE p.session_id = p_session_id AND p.id <> v_id AND coalesce(public.rpg_participant_value(p.id, 'AG'), 0) < v_ag;
  IF v_pos IS NULL THEN
    SELECT coalesce(max(turn_order), 0) + 1 INTO v_pos
      FROM public.rpg_session_participants WHERE session_id = p_session_id AND id <> v_id;
  ELSE
    UPDATE public.rpg_session_participants SET turn_order = turn_order + 1
     WHERE session_id = p_session_id AND id <> v_id AND turn_order >= v_pos;
  END IF;
  UPDATE public.rpg_session_participants SET turn_order = v_pos WHERE id = v_id;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, actor_id, text)
  VALUES (v_s.agency_id, p_session_id, v_s.round, 'join', v_id, v_name || ' joins the fight (Agility ' || trim_scale(v_ag) || ').');
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = p_session_id;
  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_auto_turn(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The site plays a creature's turn and passes it. A ready lair action is free and goes first when it is worth
-- anything. Then, while beats remain in the turn, it takes the best-scoring ready move that fits the beats left
-- (rpg_best_aim over rpg_action_score, with a little randomness): a quick Claw twice, or Claw and Rootstep, or one
-- heavy Bite. It stops when nothing ready is worth a move. Legendary actions come from the die rolled as other
-- turns end. A creature aims at the characters in the fight, not at other creatures.
DECLARE
  v_s record; v_p record; v_a record; v_targets uuid[]; v_lines jsonb := '[]'::jsonb; v_r jsonb; v_pick jsonb; v_best jsonb; v_top numeric; v_sc numeric;
  v_per integer := public.rpg_setting('beats_per_turn')::integer; v_left integer; v_guard integer := 0;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master runs a creature''s turn'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND OR v_s.status <> 'active' THEN RAISE EXCEPTION 'the fight is not on'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = v_s.current_participant_id;
  IF NOT FOUND OR v_p.creature_id IS NULL THEN RAISE EXCEPTION 'it is not a creature''s turn'; END IF;
  SELECT array_agg(p.id) INTO v_targets FROM public.rpg_session_participants p
   WHERE p.session_id = p_session_id AND p.creature_id IS NULL AND (public.rpg_participant_vitality(p.id)->>'left')::integer > 0;
  IF NOT public.rpg_participant_can_act(v_p.id) THEN
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' cannot act this turn.');
  ELSIF coalesce(cardinality(v_targets), 0) = 0 THEN
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' has no one left to attack.');
  ELSE
    v_best := NULL; v_top := 0;
    FOR v_a IN SELECT a.id, a.name FROM public.rpg_creature_actions a
                WHERE a.creature_id = v_p.creature_id AND a.kind = 'lair' AND public.rpg_action_ready(v_p.id, a.id) LOOP
      v_pick := public.rpg_best_aim(v_p.id, v_a.id, v_targets);
      IF (v_pick->>'score')::numeric > v_top THEN v_top := (v_pick->>'score')::numeric; v_best := jsonb_build_object('id', v_a.id, 'name', v_a.name, 'targets', v_pick->'targets'); END IF;
    END LOOP;
    IF v_best IS NOT NULL THEN
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' uses its lair: ' || (v_best->>'name') || '.');
      v_r := public.rpg_act(v_p.id, ARRAY(SELECT jsonb_array_elements_text(v_best->'targets'))::uuid[], NULL, (v_best->>'id')::uuid);
      v_lines := v_lines || (v_r->'results');
    END IF;
    LOOP
      v_guard := v_guard + 1;
      EXIT WHEN v_guard > 4;
      SELECT turn_beats INTO v_left FROM public.rpg_sessions WHERE id = p_session_id;
      v_left := v_per - v_left;
      EXIT WHEN v_left <= 0;
      SELECT array_agg(p.id) INTO v_targets FROM public.rpg_session_participants p
       WHERE p.session_id = p_session_id AND p.creature_id IS NULL AND (public.rpg_participant_vitality(p.id)->>'left')::integer > 0;
      EXIT WHEN coalesce(cardinality(v_targets), 0) = 0;
      v_best := NULL; v_top := 0;
      FOR v_a IN SELECT a.id, a.name, a.beats FROM public.rpg_creature_actions a
                  WHERE a.creature_id = v_p.creature_id AND a.kind IN ('action', 'bonus_action') AND a.beats <= v_left AND public.rpg_action_ready(v_p.id, a.id) LOOP
        v_pick := public.rpg_best_aim(v_p.id, v_a.id, v_targets);
        v_sc := (v_pick->>'score')::numeric * (0.85 + random() * 0.3);
        IF v_sc > v_top THEN v_top := v_sc; v_best := jsonb_build_object('id', v_a.id, 'name', v_a.name, 'targets', v_pick->'targets'); END IF;
      END LOOP;
      EXIT WHEN v_best IS NULL;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' chooses ' || (v_best->>'name') || '.');
      v_r := public.rpg_act(v_p.id, ARRAY(SELECT jsonb_array_elements_text(v_best->'targets'))::uuid[], NULL, (v_best->>'id')::uuid);
      v_lines := v_lines || (v_r->'results');
    END LOOP;
    IF jsonb_array_length(v_lines) = 0 AND (SELECT turn_beats FROM public.rpg_sessions WHERE id = p_session_id) = 0 THEN
      v_r := public.rpg_act(v_p.id, NULL, 'REST');
      v_lines := v_lines || (v_r->'results');
    END IF;
  END IF;
  PERFORM public.rpg_session_next_turn(p_session_id);
  RETURN jsonb_build_object('kind', 'auto', 'results', v_lines);
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
-- rolls a six-sided die: on 4 or more it spends one on its best ready move it can afford (rpg_best_aim; Rending
-- Swipe: one swipe at the character it scores highest on). A new round frees anyone Held from an earlier round. At
-- the start of someone's turn they get up from Knocked down, their turn count goes up and their energy regains.
-- A creature's legendary actions come back at its turn start (Bramblemaw: 3). The game master can pass any turn; a
-- player can end a character's turn, never a creature's.
DECLARE
  v_s record; v_cur_id uuid; v_cur_order integer; v_cur_created timestamptz; v_cur_creature uuid;
  v_next_id uuid; v_round integer; v_new_round boolean := false; v_next record; v_a record; v_la record;
  v_d6 integer; v_tg uuid[]; v_pick jsonb; v_best jsonb; v_top numeric;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  SELECT id, turn_order, created_at, creature_id INTO v_cur_id, v_cur_order, v_cur_created, v_cur_creature
    FROM public.rpg_session_participants WHERE id = v_s.current_participant_id AND session_id = p_session_id;
  IF NOT public.family_is_parent() THEN
    IF v_s.status <> 'active' THEN RAISE EXCEPTION 'the game master starts the fight'; END IF;
    IF v_cur_id IS NULL OR v_cur_creature IS NOT NULL THEN RAISE EXCEPTION 'the game master ends this turn'; END IF;
  END IF;

  IF v_s.status = 'active' AND v_cur_id IS NOT NULL THEN
    PERFORM set_config('rpg.engine', 'on', true);
    SELECT array_agg(p.id) INTO v_tg FROM public.rpg_session_participants p
     WHERE p.session_id = p_session_id AND p.creature_id IS NULL AND (public.rpg_participant_vitality(p.id)->>'left')::integer > 0;
    FOR v_a IN SELECT p.id, p.name, p.legendary_left, p.creature_id FROM public.rpg_session_participants p
                WHERE p.session_id = p_session_id AND p.creature_id IS NOT NULL AND p.id <> v_cur_id AND p.legendary_left > 0
                  AND public.rpg_participant_can_act(p.id) LOOP
      v_best := NULL; v_top := 0;
      FOR v_la IN SELECT a.id, a.name FROM public.rpg_creature_actions a
                   WHERE a.creature_id = v_a.creature_id AND a.kind = 'legendary' AND a.legendary_cost <= v_a.legendary_left
                     AND public.rpg_action_ready(v_a.id, a.id) LOOP
        v_pick := public.rpg_best_aim(v_a.id, v_la.id, v_tg);
        IF (v_pick->>'score')::numeric > v_top THEN
          v_top := (v_pick->>'score')::numeric; v_best := jsonb_build_object('id', v_la.id, 'name', v_la.name, 'targets', v_pick->'targets');
        END IF;
      END LOOP;
      CONTINUE WHEN v_best IS NULL;
      v_d6 := floor(random() * 6)::integer + 1;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_s.round, 'legendary', 'info', v_a.id,
              v_a.name || ' rolls a six-sided die to react: ' || v_d6 || '. ' || CASE WHEN v_d6 >= 4 THEN 'It uses ' || (v_best->>'name') || '.' ELSE 'It holds back.' END);
      IF v_d6 >= 4 THEN
        PERFORM public.rpg_act(v_a.id, ARRAY(SELECT jsonb_array_elements_text(v_best->'targets'))::uuid[], NULL, (v_best->>'id')::uuid);
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
         turn_attacks = 0, turn_beats = 0, updated_at = now()
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
  UPDATE public.rpg_session_participants
     SET turns_taken = turns_taken + 1,
         energy_used_physical = greatest(energy_used_physical - coalesce(public.rpg_participant_value(id, 'PER'), 0)::integer, 0),
         energy_used_spiritual = greatest(energy_used_spiritual - coalesce(public.rpg_participant_value(id, 'SER'), 0)::integer, 0),
         legendary_left = CASE WHEN creature_id IS NOT NULL THEN coalesce((SELECT legendary_per_round FROM public.rpg_creatures WHERE id = v_next.creature_id), 0) ELSE legendary_left END
   WHERE id = v_next_id;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  VALUES (v_s.agency_id, p_session_id, v_round, 'turn', 'info', v_next_id, v_next.name || '''s turn.');
  RETURN jsonb_build_object('round', v_round, 'current_participant_id', v_next_id);
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
-- lines with their outcome keys. A creature's numbers come from the sheet it was made with; players get creatures
-- without numbers and no game-master lists. The game master gets each creature's stats (its own card's skills
-- first) and, on every action, the number it rolls (the Bramblemaw's Claw: 10).
DECLARE
  v_gm boolean := public.family_is_parent();
  v_s record; v_p record; v_sheet jsonb; v_c record; v_vit jsonb; v_item jsonb; v_parts jsonb := '[]'::jsonb; v_vals jsonb;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  FOR v_p IN SELECT * FROM public.rpg_session_participants WHERE session_id = p_session_id ORDER BY turn_order, created_at LOOP
    IF v_p.creature_id IS NULL THEN
      v_sheet := public.rpg_sheet(v_p.character_id, public.rpg_setting('default_difficulty'));
      v_item := jsonb_build_object('kind', 'character', 'character_id', v_p.character_id, 'color', v_sheet->'color',
        'vitality_max', (v_sheet->>'vitality_max')::integer,
        'vitality_left', greatest((v_sheet->>'vitality_left')::integer, 0),
        'agility', (SELECT s->'value' FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = 'AG'),
        'weapons', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', s->>'key', 'name', s->>'name', 'value', s->'value', 'beats', d.beats, 'energy_cost', d.energy_cost, 'energy_type', d.energy_type)
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
        v_sheet := public.rpg_sheet(v_p.character_id, public.rpg_setting('default_difficulty'));
        v_vals := (SELECT coalesce(jsonb_object_agg(s->>'key', s->'value'), '{}'::jsonb) FROM jsonb_array_elements(v_sheet->'stats') s);
        v_item := v_item || jsonb_build_object(
          'vitality_max', (v_vit->>'max')::integer, 'vitality_left', (v_vit->>'left')::integer,
          'legendary_left', v_p.legendary_left, 'legendary_per_round', v_c.legendary_per_round, 'agility', v_vals->'AG',
          'skills', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', s->>'key', 'name', s->>'name', 'value', s->'value', 'own', d.template_key IS NOT NULL)
                                     ORDER BY (d.template_key IS NULL), o), '[]'::jsonb)
                       FROM jsonb_array_elements(v_sheet->'stats') WITH ORDINALITY AS t(s, o)
                       JOIN public.rpg_stat_definitions d ON d.key = s->>'key'),
          'actions', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                          'id', a.id, 'name', a.name, 'kind', a.kind, 'skill_key', coalesce(u.skill_key, a.skill_key),
                          'skill', v_vals->coalesce(u.skill_key, a.skill_key),
                          'against', coalesce(u.against, a.against), 'against_name', d.name,
                          'deals_damage', coalesce(u.deals_damage, a.deals_damage), 'table_note', a.table_note,
                          'effect', coalesce(u.effect, a.effect)->'apply'->>'name',
                          'beats', a.beats, 'area', a.area, 'energy_cost', a.energy_cost, 'energy_type', a.energy_type, 'cooldown_turns', a.cooldown_turns,
                          'ready', a.ready, 'spent', NOT a.ready,
                          'back_in', greatest(coalesce((v_p.recharge_state->>a.id::text)::integer, 0) - v_p.turns_taken, 0), 'legendary_cost', a.legendary_cost,
                          'parts', (SELECT string_agg((e->>'count') || ' × ' || (e->>'action'), ', ') FROM jsonb_array_elements(coalesce(a.makes_attacks, '[]'::jsonb)) e),
                          'usable', (SELECT coalesce(sum(greatest(coalesce((e->>'count')::integer, 1), 1)), 0) FROM jsonb_array_elements(coalesce(a.makes_attacks, '[]'::jsonb)) e) <= 1)
                        ORDER BY CASE a.kind WHEN 'action' THEN 1 WHEN 'bonus_action' THEN 2 WHEN 'reaction' THEN 3 WHEN 'legendary' THEN 4 WHEN 'lair' THEN 5 ELSE 6 END, a.sort_order), '[]'::jsonb)
                        FROM (SELECT x.*, public.rpg_action_ready(v_p.id, x.id) AS ready FROM public.rpg_creature_actions x
                               WHERE x.creature_id = v_p.creature_id AND x.kind <> 'trait') a
                        LEFT JOIN public.rpg_creature_actions u ON u.creature_id = a.creature_id AND u.name = a.makes_attacks->0->>'action'
                              AND jsonb_array_length(coalesce(a.makes_attacks, '[]'::jsonb)) = 1
                        LEFT JOIN public.rpg_stat_definitions d ON d.key = coalesce(u.against, a.against)));
      END IF;
    END IF;
    v_parts := v_parts || jsonb_build_array(jsonb_build_object('id', v_p.id, 'name', v_p.name, 'turn_order', v_p.turn_order,
                 'can_act', v_p.can_act, 'status_note', v_p.status_note, 'can_act_now', public.rpg_participant_can_act(v_p.id),
                 'effects', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', e->>'name', 'cannot_act', coalesce((e->>'cannot_act')::boolean, false), 'source', e->>'source')), '[]'::jsonb)
                               FROM jsonb_array_elements(v_p.effects) e),
                 'energy', public.rpg_participant_energy(v_p.id), 'is_current', coalesce(v_p.id = v_s.current_participant_id, false)) || v_item);
  END LOOP;
  RETURN jsonb_build_object(
    'session', jsonb_build_object('id', v_s.id, 'name', v_s.name, 'status', v_s.status, 'round', v_s.round,
                 'current_participant_id', v_s.current_participant_id, 'turn_attacks', v_s.turn_attacks,
                 'turn_beats', v_s.turn_beats, 'beats_per_turn', public.rpg_setting('beats_per_turn'), 'updated_at', v_s.updated_at),
    'is_gm', v_gm,
    'participants', v_parts,
    'events', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'round', e.round, 'kind', e.kind, 'outcome', e.outcome, 'text', e.text,
                                          'damage', e.damage, 'created_at', e.created_at) ORDER BY e.created_at DESC), '[]'::jsonb)
                 FROM (SELECT * FROM public.rpg_events WHERE session_id = p_session_id ORDER BY created_at DESC LIMIT 60) e),
    'available', CASE WHEN v_gm THEN jsonb_build_object(
        'characters', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) ORDER BY c.name), '[]'::jsonb)
                         FROM public.rpg_characters c
                        WHERE c.is_active AND c.session_id IS NULL
                          AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants p WHERE p.session_id = p_session_id AND p.character_id = c.id)),
        'creatures', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) ORDER BY c.sort_order, c.name), '[]'::jsonb)
                        FROM public.rpg_creatures c
                       WHERE c.is_active AND EXISTS (SELECT 1 FROM public.rpg_creature_actions a WHERE a.creature_id = c.id AND a.kind <> 'trait'))) END);
END;
$function$;
-- A card action may only roll, contest with, or give a bonus to stats its card has.
CREATE OR REPLACE FUNCTION public.rpg_creature_actions_skill_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- An action can only use stats its card has: a shared one, or one that belongs to the card or a card above it
-- (rpg_template_stat_defs). That holds for the skill it rolls (skill_key), the skill a contest rolls, and every stat
-- an effect gives a bonus to. The Bramblemaw's Claw may roll Claw; the Boar's Gore may not. Sink Into Soil may give
-- Evade Enemy (EE) + 4; a bonus to "defense" is refused, because no sheet has a stat by that name.
DECLARE v_card text; v_name text; v_k text;
BEGIN
  SELECT c.key, c.name INTO v_card, v_name FROM public.rpg_creatures c WHERE c.id = NEW.creature_id;
  IF NEW.skill_key IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.rpg_template_stat_defs(v_card) d WHERE d.key = NEW.skill_key) THEN
    RAISE EXCEPTION '% on the % card cannot roll %: the card does not have that skill', NEW.name, v_name, NEW.skill_key;
  END IF;
  IF NEW.effect->'contest'->>'skill_key' IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.rpg_template_stat_defs(v_card) d WHERE d.key = NEW.effect->'contest'->>'skill_key') THEN
    RAISE EXCEPTION '% on the % card cannot contest with %: the card does not have that stat', NEW.name, v_name, NEW.effect->'contest'->>'skill_key';
  END IF;
  IF jsonb_typeof(NEW.effect->'apply'->'bonus') = 'object' THEN
    FOR v_k IN SELECT jsonb_object_keys(NEW.effect->'apply'->'bonus') LOOP
      IF NOT EXISTS (SELECT 1 FROM public.rpg_template_stat_defs(v_card) d WHERE d.key = v_k) THEN
        RAISE EXCEPTION '% on the % card gives a bonus to %, which the card does not have', NEW.name, v_name, v_k;
      END IF;
    END LOOP;
  END IF;
  RETURN NEW;
END;
$function$;
DROP TRIGGER IF EXISTS rpg_creature_actions_skill_check ON public.rpg_creature_actions;
CREATE TRIGGER rpg_creature_actions_skill_check BEFORE INSERT OR UPDATE OF skill_key, creature_id, effect ON public.rpg_creature_actions
  FOR EACH ROW EXECUTE FUNCTION public.rpg_creature_actions_skill_check();

-- Sink Into Soil's bonus now names the sheet stat it raises.
UPDATE public.rpg_creature_actions a
   SET effect = jsonb_set(a.effect, '{apply,bonus}', '{"EE": 4}'::jsonb)
  FROM public.rpg_creatures c
 WHERE c.id = a.creature_id AND c.key = 'bramblemaw' AND a.name = 'Sink Into Soil' AND a.effect->'apply'->'bonus' = '{"defense": 4}'::jsonb;

-- The fight still open when this shipped gets its creature made from its card, carrying the damage it had taken.
SELECT set_config('request.jwt.claims', '{"sub":"dc9a6291-6d79-410b-9870-ff5d0c81a7f0","role":"authenticated"}', true);
UPDATE public.rpg_session_participants p
   SET character_id = public.rpg_new_character(p.name, NULL, true, c.key)
  FROM public.rpg_creatures c, public.rpg_sessions s
 WHERE c.id = p.creature_id AND s.id = p.session_id AND p.character_id IS NULL AND s.status <> 'ended';
UPDATE public.rpg_characters ch
   SET session_id = p.session_id,
       vitality_damage = least(p.vitality_damage, (public.rpg_sheet_values(ch.id)->>'vitality_max')::numeric)::integer
  FROM public.rpg_session_participants p
 WHERE p.character_id = ch.id AND p.creature_id IS NOT NULL AND ch.session_id IS NULL;
UPDATE public.rpg_session_participants p
   SET effects = (SELECT coalesce(jsonb_agg(CASE WHEN e->'bonus' ? 'defense'
                                                 THEN jsonb_set(e, '{bonus}', (e->'bonus') - 'defense' || jsonb_build_object('EE', e->'bonus'->'defense'))
                                                 ELSE e END), '[]'::jsonb)
                    FROM jsonb_array_elements(p.effects) e)
 WHERE p.effects::text LIKE '%"defense"%';
SELECT set_config('request.jwt.claims', '', true);
ALTER TABLE public.rpg_session_participants ALTER COLUMN character_id SET NOT NULL;
-- Rule cards follow the engine: creatures fight on their own sheets.
UPDATE public.rpg_rules SET body = replace(body,
  'A creature''s pools come from its strength and will the same way (Bramblemaw: 30 and 30, regains 5 and 5).',
  'A creature''s pools come from its own sheet the same way (a Bramblemaw: Endurance 15 → pool 45, regain 7; Shield of Faith 10 → pool 30; Hope 9 → regain 4).')
 WHERE key = 'energy';
UPDATE public.rpg_rules SET body = replace(body,
  '(Evade Enemy for a blow; Boots of the Gospel of Peace for a spiritual attack; a creature''s defense or will)',
  '(Evade Enemy for a blow; Boots of the Gospel of Peace for a spiritual attack; a creature has the same stats on its own sheet)')
 WHERE key = 'attack_gates';
UPDATE public.rpg_rules SET body = replace(body,
  'Until fights make each creature from its card, a fight still uses the numbers printed on the card, with no Integrity. They match a typical creature made from that card.',
  'Every creature that joins a fight is made fresh from its card, so two Ashwing Harriers are two different rolls (Physical Vitality 40 to 50), while every Bramblemaw comes out the same. Its moves are the actions on its card, each rolling one of its own skills, and it learns from its rolls the way you do.')
 WHERE key = 'creature_conversion';
UPDATE public.rpg_rules SET body = replace(replace(body,
  'On your turn you make one attack, then end your turn. Creatures follow their card: Bramblemaw''s Multiattack is two Claw rolls and one Bite roll.',
  'On your turn you spend its beats (see below), then end your turn. A creature''s moves are the actions on its card, each rolling one of its own skills: the Bramblemaw''s Claw rolls its Claw 10.'),
  'When a creature''s turn starts, its legendary actions come back (Bramblemaw has 3), and each recharge action it has used rolls a six-sided die: Briar Roar is ready again on a 5 or 6.',
  'When a creature''s turn starts, its legendary actions come back (Bramblemaw has 3).')
 WHERE key = 'turn_order';

