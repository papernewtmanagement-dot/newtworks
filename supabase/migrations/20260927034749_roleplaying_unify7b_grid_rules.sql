-- Roleplaying unify7b: the fight grid's rules. Every roll at a target must reach it (rpg_act); the site aims only at
-- targets in reach, a single-target action at one target (rpg_best_aim), walks a creature toward the nearest
-- character when nothing is in reach (rpg_session_auto_turn), and uses Rootstep and Briar Shift on squares
-- (rpg_session_next_turn, rpg_session_auto_turn). The fight screen gets the board (rpg_session_state) and every
-- action line its reach (rpg_action_text). Retired because they drove nothing: rpg_creature_actions.makes_attacks
-- (empty on every card since Multiattack went) and rpg_sessions.turn_attacks (only ever reset).

CREATE FUNCTION pg_temp.rep(p_def text, p_old text, p_new text, p_label text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n integer := (length(p_def) - length(replace(p_def, p_old, ''))) / length(p_old);
BEGIN
  IF n <> 1 THEN RAISE EXCEPTION 'anchor % found % times', p_label, n; END IF;
  RETURN replace(p_def, p_old, p_new);
END $f$;
CREATE FUNCTION pg_temp.rx(p_def text, p_pat text, p_new text, p_label text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n integer := (SELECT count(*) FROM regexp_matches(p_def, p_pat, 'g'));
BEGIN
  IF n <> 1 THEN RAISE EXCEPTION 'pattern % found % times', p_label, n; END IF;
  RETURN regexp_replace(p_def, p_pat, p_new);
END $f$;

-- rpg_act was last changed by anchored patches, so it is patched the same way.
DO $do$
DECLARE v text := pg_get_functiondef('public.rpg_act(uuid,uuid[],text,uuid,text,numeric,integer,text)'::regprocedure);
BEGIN
  v := pg_temp.rep(v, $a$v_integrity integer; v_bounced boolean;$a$,
                      $b$v_integrity integer; v_bounced boolean; v_reach integer; v_rname text; v_area boolean;$b$, 'act declare');
  v := pg_temp.rep(v, $a$--   for is refused.$a$,
$b$--   for is refused. Every roll at a target must reach it on the fight grid (rpg_in_reach): Claw 1 square, Briar Roar
--   6, Longbow 12, counted as the larger gap across or up-down; someone not on the board is always in reach. A card
--   action that is not an area action aims at one target.$b$, 'act comment');
  v := pg_temp.rep(v, $a$  -- A creature at 0 vitality is out of reach: dead, or waiting$a$,
$b$  -- Reach on the fight grid: the card action's reach, or the rolled skill's.
  IF p_effect IS NULL AND cardinality(v_targets) > 0 THEN
    IF p_action_id IS NOT NULL THEN
      SELECT reach, name, area INTO v_reach, v_rname, v_area FROM public.rpg_creature_actions WHERE id = p_action_id;
      IF cardinality(v_targets) > 1 AND NOT coalesce(v_area, false) THEN RAISE EXCEPTION '% aims at one target', v_rname; END IF;
    ELSE
      SELECT reach, name INTO v_reach, v_rname FROM public.rpg_stat_definitions WHERE key = p_stat_key;
    END IF;
    FOR v_tid IN SELECT unnest(v_targets) LOOP
      IF NOT public.rpg_in_reach(p_actor_id, v_tid, coalesce(v_reach, 1)) THEN
        RAISE EXCEPTION '% is % squares away and % reaches %', (SELECT name FROM public.rpg_session_participants WHERE id = v_tid),
          public.rpg_distance(p_actor_id, v_tid), coalesce(v_rname, 'that roll'), coalesce(v_reach, 1);
      END IF;
    END LOOP;
  END IF;
  -- A creature at 0 vitality is out of reach: dead, or waiting$b$, 'act reach');
  v := pg_temp.rep(v, $a$  IF v_kind = 'action' AND jsonb_array_length(v_plan) = 0 THEN
$a$, $b$  IF v_kind = 'action' AND jsonb_array_length(v_plan) = 0 THEN
    IF v_act.effect->>'on' IN ('step', 'board') THEN RAISE EXCEPTION 'choose a square on the board for %', v_act.name; END IF;
$b$, 'act square');
  v := pg_temp.rep(v, $a$    IF (SELECT coalesce(sum(greatest(coalesce((e->>'count')::integer, 1), 1)), 0) FROM jsonb_array_elements(coalesce(v_act.makes_attacks, '[]'::jsonb)) e) > 1 THEN
      RAISE EXCEPTION '% makes one attack a turn; % is not used. Pick one of its attacks', v_actor.name, v_act.name;
    END IF;
$a$, '', 'act multiattack guard');
  v := pg_temp.rep(v, $a$    IF jsonb_typeof(v_act.makes_attacks) = 'array' AND jsonb_array_length(v_act.makes_attacks) > 0 THEN
      IF cardinality(v_targets) = 0 THEN RAISE EXCEPTION 'choose who % is aimed at', v_act.name; END IF;
      FOR v_e IN SELECT e FROM jsonb_array_elements(v_act.makes_attacks) e LOOP
        SELECT id INTO v_cid FROM public.rpg_creature_actions WHERE creature_id = v_actor.creature_id AND name = v_e->>'action' LIMIT 1;
        IF NOT FOUND THEN RAISE EXCEPTION '% names an attack that is not on the card', v_act.name; END IF;
        FOR v_n IN 1..greatest(coalesce((v_e->>'count')::integer, 1), 1) LOOP
          v_plan := v_plan || jsonb_build_object('a', v_cid, 't', v_targets[1 + floor(random() * cardinality(v_targets))::integer]);
        END LOOP;
      END LOOP;
    ELSIF v_act.skill_key IS NOT NULL THEN$a$, $b$    IF v_act.skill_key IS NOT NULL THEN$b$, 'act multiattack plan');
  EXECUTE v;
END $do$;

DO $do$
DECLARE v text := pg_get_functiondef('public.rpg_action_score(uuid,uuid,uuid)'::regprocedure);
BEGIN
  v := pg_temp.rep(v, $a$  IF jsonb_typeof(v_a.makes_attacks) = 'array' AND jsonb_array_length(v_a.makes_attacks) = 1 AND coalesce((v_a.makes_attacks->0->>'count')::integer, 1) = 1 THEN
    SELECT * INTO v_u FROM public.rpg_creature_actions WHERE creature_id = v_a.creature_id AND name = v_a.makes_attacks->0->>'action' LIMIT 1;
    IF NOT FOUND THEN RETURN 0; END IF;
  ELSE
    v_u := v_a;
  END IF;$a$, $b$  v_u := v_a;$b$, 'score multiattack');
  EXECUTE v;
END $do$;

DO $do$
DECLARE v text := pg_get_functiondef('public.rpg_session_next_turn(uuid)'::regprocedure);
BEGIN
  v := pg_temp.rep(v, $a$scores highest on). A new round$a$,
                      $b$scores highest on; Rootstep: a step toward the nearest character). A new round$b$, 'next comment');
  v := pg_temp.rep(v, $a$turn_attacks = 0, turn_beats = 0, updated_at = now()$a$,
                      $b$turn_beats = 0, turn_move_left = 0, updated_at = now()$b$, 'next reset');
  v := pg_temp.rep(v, $a$v_best := jsonb_build_object('id', v_la.id, 'name', v_la.name, 'targets', v_pick->'targets');$a$,
                      $b$v_best := jsonb_build_object('id', v_la.id, 'name', v_la.name, 'targets', v_pick->'targets', 'square', v_pick->'square');$b$, 'next pick');
  v := pg_temp.rep(v, $a$        PERFORM public.rpg_act(v_a.id, ARRAY(SELECT jsonb_array_elements_text(v_best->'targets'))::uuid[], NULL, (v_best->>'id')::uuid);$a$,
$b$        IF jsonb_typeof(v_best->'square') = 'object' THEN
          PERFORM public.rpg_act_square(v_a.id, (v_best->'square'->>'x')::integer, (v_best->'square'->>'y')::integer, (v_best->>'id')::uuid);
        ELSE
          PERFORM public.rpg_act(v_a.id, ARRAY(SELECT jsonb_array_elements_text(v_best->'targets'))::uuid[], NULL, (v_best->>'id')::uuid);
        END IF;$b$, 'next act');
  EXECUTE v;
END $do$;

DO $do$
DECLARE v text := pg_get_functiondef('public.rpg_session_state(uuid)'::regprocedure);
BEGIN
  v := pg_temp.rep(v, $a$-- or its revival rule's name (Sunk), and 'revival' says when it rises and which roll ends it for good.$a$,
$b$-- or its revival rule's name (Sunk), and 'revival' says when it rises and which roll ends it for good.
-- The board: its size, each square's movement penalty (terrain), where everyone stands, how far a beat of movement
-- takes each (rpg_move_per_beat), each weapon's and action's reach, and the squares the one whose turn it is can
-- still reach this turn ('moves', with what each costs and the beats that takes).$b$, 'state comment');
  v := pg_temp.rep(v, $a$'current_participant_id', v_s.current_participant_id, 'turn_attacks', v_s.turn_attacks,$a$,
$b$'current_participant_id', v_s.current_participant_id, 'grid_w', v_s.grid_w, 'grid_h', v_s.grid_h,
                 'terrain', v_s.terrain, 'turn_move_left', v_s.turn_move_left,$b$, 'state session');
  v := pg_temp.rep(v, $a$'skill_key', coalesce(u.skill_key, a.skill_key),$a$, $b$'skill_key', a.skill_key,$b$, 'state skill_key');
  v := pg_temp.rep(v, $a$'skill', v_vals->coalesce(u.skill_key, a.skill_key),$a$, $b$'skill', v_vals->a.skill_key,$b$, 'state skill');
  v := pg_temp.rep(v, $a$public.rpg_action_text(coalesce(u.id, a.id), (v_vals->>coalesce(u.skill_key, a.skill_key))::numeric)$a$,
                      $b$public.rpg_action_text(a.id, (v_vals->>a.skill_key)::numeric)$b$, 'state line');
  v := pg_temp.rep(v, $a$'usable', (SELECT coalesce(sum(greatest(coalesce((e->>'count')::integer, 1), 1)), 0) FROM jsonb_array_elements(coalesce(a.makes_attacks, '[]'::jsonb)) e) <= 1)$a$,
                      $b$'reach', a.reach, 'square', coalesce(a.effect->>'on' IN ('step', 'board'), false))$b$, 'state usable');
  v := pg_temp.rx(v, $p$\) a\s+LEFT JOIN public\.rpg_creature_actions u ON u\.creature_id = a\.creature_id AND u\.name = a\.makes_attacks->0->>'action'\s+AND jsonb_array_length\(coalesce\(a\.makes_attacks, '\[\]'::jsonb\)\) = 1\)\);$p$,
                     ') a));', 'state join');
  v := pg_temp.rep(v, $a$'beats', d.beats, 'energy_cost', d.energy_cost, 'energy_type', d.energy_type)$a$,
                      $b$'beats', d.beats, 'energy_cost', d.energy_cost, 'energy_type', d.energy_type, 'reach', d.reach)$b$, 'state weapons');
  v := pg_temp.rep(v, $a$'is_current', coalesce(v_p.id = v_s.current_participant_id, false)) || v_item);$a$,
$b$'is_current', coalesce(v_p.id = v_s.current_participant_id, false),
                 'pos_x', v_p.pos_x, 'pos_y', v_p.pos_y, 'move_per_beat', public.rpg_move_per_beat(v_p.id)) || v_item);$b$, 'state parts');
  v := pg_temp.rep(v, $a$    'is_gm', v_gm,$a$,
$b$    'is_gm', v_gm,
    'moves', CASE WHEN v_s.current_participant_id IS NULL THEN '[]'::jsonb ELSE public.rpg_move_options(v_s.current_participant_id) END,$b$, 'state moves');
  EXECUTE v;
END $do$;

CREATE OR REPLACE FUNCTION public.rpg_best_aim(p_actor_id uuid, p_action_id uuid, p_targets uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where the site aims an action. Only targets in the action's reach count (rpg_in_reach: Claw 1 square, Briar Roar
-- 6). An area action (Briar Roar, Rending Swipe) goes at everyone in reach it scores anything on; any other goes at
-- the one target it scores highest on (Claw, Judging Gaze). An action on the creature itself (Sink Into Soil) needs
-- no target and is worth 10 unless it already has that effect. A step (Rootstep) is worth 8 when no character is next
-- to it and it can get closer (rpg_step_target); a board action (Briar Shift) is worth 5 at the square of the nearest
-- character in its reach who is not next to it and whose ground is not already hard (penalty under 4). Returns the
-- targets, the score, and for a step or board action the square; 0 with no targets when nothing is worth doing.
DECLARE v_a record; v_t uuid; v_sc numeric; v_best uuid; v_top numeric := 0; v_list uuid[] := '{}'; v_sum numeric := 0; v_sq jsonb;
BEGIN
  SELECT * INTO v_a FROM public.rpg_creature_actions WHERE id = p_action_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('targets', '[]'::jsonb, 'score', 0); END IF;
  IF v_a.effect->>'on' = 'self' THEN
    RETURN jsonb_build_object('targets', '[]'::jsonb, 'score',
      CASE WHEN EXISTS (SELECT 1 FROM public.rpg_session_participants p, jsonb_array_elements(p.effects) e WHERE p.id = p_actor_id AND e->>'name' = v_a.effect->'apply'->>'name') THEN 0 ELSE 10 END);
  END IF;
  IF v_a.effect->>'on' = 'step' THEN
    v_sq := public.rpg_step_target(p_actor_id, public.rpg_move_per_beat(p_actor_id) * coalesce((v_a.effect->>'beats')::integer, 1));
    RETURN jsonb_build_object('targets', '[]'::jsonb, 'score', CASE WHEN v_sq IS NULL THEN 0 ELSE 8 END, 'square', v_sq);
  END IF;
  IF v_a.effect->>'on' = 'board' THEN
    SELECT jsonb_build_object('x', p.pos_x, 'y', p.pos_y) INTO v_sq
      FROM unnest(coalesce(p_targets, '{}'::uuid[])) AS t(id)
      JOIN public.rpg_session_participants p ON p.id = t.id
      JOIN public.rpg_sessions s ON s.id = p.session_id
     WHERE p.pos_x IS NOT NULL AND public.rpg_distance(p_actor_id, p.id) BETWEEN 2 AND v_a.reach
       AND coalesce((s.terrain->>(p.pos_x || ',' || p.pos_y))::integer, 0) < 4
     ORDER BY public.rpg_distance(p_actor_id, p.id), p.pos_y, p.pos_x LIMIT 1;
    RETURN jsonb_build_object('targets', '[]'::jsonb, 'score', CASE WHEN v_sq IS NULL THEN 0 ELSE 5 END, 'square', v_sq);
  END IF;
  FOREACH v_t IN ARRAY coalesce(p_targets, '{}'::uuid[]) LOOP
    CONTINUE WHEN NOT public.rpg_in_reach(p_actor_id, v_t, v_a.reach);
    v_sc := public.rpg_action_score(p_actor_id, p_action_id, v_t);
    IF NOT v_a.area THEN
      IF v_sc > v_top THEN v_top := v_sc; v_best := v_t; END IF;
    ELSIF v_sc > 0 THEN
      v_list := v_list || v_t; v_sum := v_sum + v_sc;
    END IF;
  END LOOP;
  IF NOT v_a.area THEN
    RETURN jsonb_build_object('targets', CASE WHEN v_best IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(v_best) END, 'score', v_top);
  END IF;
  RETURN jsonb_build_object('targets', to_jsonb(v_list), 'score', v_sum);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_auto_turn(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The site plays a creature's turn and passes it. A ready lair action is free and goes first when it is worth
-- anything (Briar Shift goes on a square). Then, while beats remain in the turn, it takes the best-scoring ready move
-- that fits the beats left and reaches someone (rpg_best_aim over rpg_action_score, with a little randomness): a
-- quick Claw twice, or one heavy Bite. When nothing in reach is worth a move it walks one beat toward the nearest
-- character (rpg_step_target) and looks again: the Bramblemaw 4 squares from Karen walks 3 for 1 beat, then claws
-- with the other. It stops when nothing is worth a move and it cannot get closer. Legendary actions come from the die
-- rolled as other turns end. A creature aims at the characters in the fight, not at other creatures.
DECLARE
  v_s record; v_p record; v_a record; v_targets uuid[]; v_lines jsonb := '[]'::jsonb; v_r jsonb; v_pick jsonb; v_best jsonb; v_top numeric; v_sc numeric;
  v_per integer := public.rpg_setting('beats_per_turn')::integer; v_left integer; v_guard integer := 0; v_step jsonb;
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
      IF (v_pick->>'score')::numeric > v_top THEN
        v_top := (v_pick->>'score')::numeric;
        v_best := jsonb_build_object('id', v_a.id, 'name', v_a.name, 'targets', v_pick->'targets', 'square', v_pick->'square');
      END IF;
    END LOOP;
    IF v_best IS NOT NULL THEN
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' uses its lair: ' || (v_best->>'name') || '.');
      IF jsonb_typeof(v_best->'square') = 'object' THEN
        v_r := public.rpg_act_square(v_p.id, (v_best->'square'->>'x')::integer, (v_best->'square'->>'y')::integer, (v_best->>'id')::uuid);
      ELSE
        v_r := public.rpg_act(v_p.id, ARRAY(SELECT jsonb_array_elements_text(v_best->'targets'))::uuid[], NULL, (v_best->>'id')::uuid);
      END IF;
      v_lines := v_lines || (v_r->'results');
    END IF;
    LOOP
      v_guard := v_guard + 1;
      EXIT WHEN v_guard > 6;
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
      IF v_best IS NULL THEN
        v_step := public.rpg_step_target(v_p.id, public.rpg_move_per_beat(v_p.id) + (SELECT turn_move_left FROM public.rpg_sessions WHERE id = p_session_id));
        EXIT WHEN v_step IS NULL;
        v_r := public.rpg_act_square(v_p.id, (v_step->>'x')::integer, (v_step->>'y')::integer);
        v_lines := v_lines || (v_r->'results');
        CONTINUE;
      END IF;
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

CREATE OR REPLACE FUNCTION public.rpg_action_text(p_action_id uuid, p_skill numeric DEFAULT NULL::numeric)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One plain line for what a card's action does, built only from its row: the beats it takes on the creature's own
-- turn (actions only; a turn has beats_per_turn), its energy, its reach in squares, the skill it rolls against which
-- stat × the opponent multiplier, whether it does damage, and its effect. With p_skill (a fight) the line carries the
-- creature's number: "1 beat · 3 physical energy · Reach 1 square · Rolls its Claw 10 against the target's Evade
-- Enemy × 2 and does damage. A hit also rolls its Strength against the target's Strength × 2; if that lands, the
-- target is Knocked down and cannot act until their turn starts." A step (Rootstep) says how far it goes; a board
-- action (Briar Shift) what it does to the ground. A revival rule (a trait whose effect is on 'zero') gets its own
-- line: "At 0 vitality it is Sunk and cannot act or be reached; after 2 rounds it rises with 1 vitality. A character
-- ends it for good by rolling Healing (Spiritual) against its Fascination with Evil × 2 (Sanctified)." So does a
-- movement trait (Forest-Bound Terror). Other traits get no line.
-- An effect that exposes (Silenced, Judged) says who faces the target at × 1: every attacker, or the creature itself.
DECLARE
  a        public.rpg_creature_actions%ROWTYPE;
  v_names  jsonb;
  v_m      text := trim_scale(public.rpg_setting('opponent_will_multiplier'))::text;
  v_per    numeric := public.rpg_setting('beats_per_turn');
  v_parts  text[] := '{}';
  v_fx     jsonb;
  v_ap     jsonb;
  v_fxt    text;
  v_line   text;
  v_n      integer;
BEGIN
  SELECT * INTO a FROM public.rpg_creature_actions WHERE id = p_action_id;
  IF NOT FOUND OR (a.kind = 'trait' AND coalesce(a.effect->>'on', '') NOT IN ('zero', 'move')) THEN RETURN NULL; END IF;
  SELECT jsonb_object_agg(d.key, d.name) INTO v_names
    FROM public.rpg_stat_definitions d WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365';
  IF a.effect->>'on' = 'zero' THEN
    RETURN 'At 0 vitality it is ' || (a.effect->'apply'->>'name') || ' and cannot act or be reached; after '
        || (a.effect->'apply'->>'rounds') || ' rounds it rises with ' || coalesce(a.effect->'apply'->>'revive', '1') || ' vitality.'
        || CASE WHEN a.effect ? 'ended_by' THEN ' A character ends it for good by rolling '
             || coalesce(v_names->>(a.effect->'ended_by'->>'skill_key'), a.effect->'ended_by'->>'skill_key') || ' against its '
             || coalesce(v_names->>(a.effect->'ended_by'->>'against'), a.effect->'ended_by'->>'against') || ' × ' || v_m
             || ' (' || (a.effect->'ended_by'->>'name') || ').' ELSE '' END;
  END IF;
  IF a.effect->>'on' = 'move' THEN
    RETURN CASE WHEN coalesce((a.effect->>'ignore_penalty')::boolean, false)
                THEN 'Movement penalties never slow it: every square costs it 1 to step into.' END;
  END IF;

  IF a.kind IN ('action', 'bonus_action') AND coalesce(a.beats, 0) > 0 THEN
    v_parts := v_parts || (a.beats || CASE WHEN a.beats = 1 THEN ' beat' ELSE ' beats' END
                           || CASE WHEN a.beats >= v_per THEN ' (the whole turn)' ELSE '' END);
  END IF;
  IF coalesce(a.energy_cost, 0) > 0 THEN
    v_parts := v_parts || (a.energy_cost || ' ' || a.energy_type || ' energy');
  END IF;
  IF a.skill_key IS NOT NULL OR a.effect->>'on' = 'board' THEN
    v_parts := v_parts || ('Reach ' || a.reach || CASE WHEN a.reach = 1 THEN ' square' ELSE ' squares' END);
  END IF;
  IF a.skill_key IS NOT NULL THEN
    v_parts := v_parts || ('Rolls its ' || coalesce(v_names->>a.skill_key, a.skill_key)
                           || coalesce(' ' || trim_scale(p_skill)::text, '')
                           || ' against ' || CASE WHEN a.area THEN 'each target''s ' ELSE 'the target''s ' END
                           || coalesce(v_names->>a.against, a.against) || ' × ' || v_m
                           || CASE WHEN a.deals_damage THEN ' and does damage' ELSE '' END);
  END IF;
  IF a.effect->>'on' = 'step' THEN
    v_n := coalesce((a.effect->>'beats')::integer, 1);
    v_parts := v_parts || ('Moves as far as ' || v_n || CASE WHEN v_n = 1 THEN ' beat' ELSE ' beats' END || ' of its movement takes it');
  END IF;
  IF a.effect->>'on' = 'board' THEN
    v_parts := v_parts || ('Every square within ' || coalesce(a.effect->>'radius', '0') || ' of a square in reach gets '
                           || coalesce(a.effect->>'raise', '1') || ' more movement penalty, up to 9');
  END IF;
  v_line := array_to_string(v_parts, ' · ');

  v_fx := a.effect;
  IF v_fx IS NOT NULL AND v_fx ? 'apply' THEN
    v_ap := v_fx->'apply';
    IF v_fx->>'on' = 'self' THEN
      v_fxt := 'It is ' || (v_ap->>'name')
            || coalesce(' (' || (SELECT string_agg(coalesce(v_names->>b.k, b.k) || ' +' || b.v, ', ')
                                   FROM jsonb_each_text(v_ap->'bonus') AS b(k, v)) || ')', '')
            || CASE v_ap->>'clear' WHEN 'turn_start' THEN ' until its next turn starts'
                                   WHEN 'round' THEN ' until the next round' ELSE '' END;
    ELSE
      v_fxt := CASE
                 WHEN v_fx->>'on' = 'hit' AND v_fx ? 'contest' THEN
                   'A hit also rolls its ' || coalesce(v_names->>(v_fx->'contest'->>'skill_key'), v_fx->'contest'->>'skill_key')
                   || ' against the target''s ' || coalesce(v_names->>(v_fx->'contest'->>'against'), v_fx->'contest'->>'against')
                   || ' × ' || v_m || '; if that lands, the target is '
                 WHEN v_fx->>'on' = 'hit' THEN 'A hit also leaves the target '
                 WHEN a.area THEN 'Those it beats are '
                 ELSE 'If it beats the target, they are '
               END
            || (v_ap->>'name')
            || CASE WHEN coalesce((v_ap->>'cannot_act')::boolean, false) THEN ' and cannot act' ELSE '' END
            || CASE v_ap->>'clear'
                 WHEN 'turn_start' THEN ' until their turn starts'
                 WHEN 'round' THEN ' until the next round'
                 WHEN 'source_turn' THEN ' until its next turn starts'
                 WHEN 'check' THEN ': on each of their turns they roll '
                                   || coalesce(v_names->>(v_ap->>'check_stat'), v_ap->>'check_stat')
                                   || ' against ' || trim_scale((v_ap->>'check_difficulty')::numeric)::text || ' to shake it off'
                                   || CASE WHEN v_ap->>'on_fail' = 'no_attack' THEN ', and if that fails they cannot attack that turn' ELSE '' END
                 ELSE '' END
            || CASE v_ap->>'exposed'
                 WHEN 'all' THEN ', and every attacker faces their Evade Enemy × 1'
                 WHEN 'source' THEN ', and its own attacks face their Evade Enemy × 1'
                 ELSE '' END;
    END IF;
    v_line := CASE WHEN v_line = '' THEN v_fxt ELSE v_line || '. ' || v_fxt END;
  END IF;
  RETURN nullif(v_line, '') || CASE WHEN nullif(v_line, '') IS NULL THEN '' ELSE '.' END;
END;
$function$;

ALTER TABLE public.rpg_creature_actions DROP COLUMN IF EXISTS makes_attacks;
ALTER TABLE public.rpg_sessions DROP COLUMN IF EXISTS turn_attacks;

DO $do$
BEGIN
  IF has_function_privilege('authenticated', 'public.rpg_grid_costs(uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.rpg_best_aim(uuid,uuid,uuid[])', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.rpg_action_text(uuid,numeric)', 'EXECUTE') THEN
    RAISE EXCEPTION 'an internal fight function is open to players';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.rpg_act(uuid,uuid[],text,uuid,text,numeric,integer,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpg_session_next_turn(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpg_session_auto_turn(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpg_session_state(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpg_act_square(uuid,integer,integer,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'a fight function lost its grant';
  END IF;
END $do$;

