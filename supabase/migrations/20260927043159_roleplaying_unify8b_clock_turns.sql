-- Roleplaying unify8b: the fight clock reaches the one-move function, the fight screen, joining a fight, the action
-- line and the rules. A turn holds one action (an attack, a card action, Rest or Defend); its ticks come from the
-- fighter's Speed (rpg_action_ticks). The old 2-beat turn and movement per beat are dropped.

CREATE FUNCTION pg_temp.rep(p_def text, p_old text, p_new text, p_label text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n integer := (length(p_def) - length(replace(p_def, p_old, ''))) / length(p_old);
BEGIN
  IF n <> 1 THEN RAISE EXCEPTION 'anchor % found % times', p_label, n; END IF;
  RETURN replace(p_def, p_old, p_new);
END $f$;

DO $do$
DECLARE v text := pg_get_functiondef('public.rpg_act(uuid,uuid[],text,uuid,text,numeric,integer,text)'::regprocedure);
BEGIN
  v := pg_temp.rep(v, $a$cost beats of the turn and energy$a$, $b$cost time on the fight clock (rpg_action_ticks; one action a turn) and energy$b$, 'act comment');
  v := pg_temp.rep(v, $a$ v_per integer := public.rpg_setting('beats_per_turn')::integer;$a$, '', 'act v_per');
  v := pg_temp.rep(v, $a$    IF v_s.turn_beats > 0 THEN RAISE EXCEPTION '% has already used part of this turn', v_actor.name; END IF;$a$,
                      $b$    IF v_s.turn_action_ticks > 0 THEN RAISE EXCEPTION '% has already acted this turn', v_actor.name; END IF;$b$, 'act rest check');
  v := pg_temp.rep(v, $a$    UPDATE public.rpg_sessions SET turn_beats = v_per, updated_at = now() WHERE id = v_s.id;$a$,
                      $b$    UPDATE public.rpg_sessions SET turn_action_ticks = public.rpg_action_ticks(p_actor_id, public.rpg_setting('rest_beats')), updated_at = now() WHERE id = v_s.id;$b$, 'act rest charge');
  v := pg_temp.rep(v, $a$      IF v_s.turn_beats + v_beats > v_per THEN RAISE EXCEPTION '% has % of % beats left this turn and % takes %', v_actor.name, v_per - v_s.turn_beats, v_per, v_stat_name, v_beats; END IF;$a$,
                      $b$      IF v_s.turn_action_ticks > 0 THEN RAISE EXCEPTION '% has already acted this turn', v_actor.name; END IF;$b$, 'act attack check');
  v := pg_temp.rep(v, $a$        IF v_s.turn_beats + coalesce(v_beats, 0) > v_per THEN RAISE EXCEPTION '% has % of % beats left this turn and % takes %', v_actor.name, v_per - v_s.turn_beats, v_per, v_stat_name, v_beats; END IF;$a$,
                      $b$        IF v_s.turn_action_ticks > 0 THEN RAISE EXCEPTION '% has already acted this turn', v_actor.name; END IF;$b$, 'act ending check');
  v := pg_temp.rep(v, $a$      IF v_s.turn_beats + v_act.beats > v_per THEN
        RAISE EXCEPTION '% has % of % beats left this turn and % takes %', v_actor.name, v_per - v_s.turn_beats, v_per, v_act.name, v_act.beats;
      END IF;$a$, $b$      IF v_s.turn_action_ticks > 0 THEN RAISE EXCEPTION '% has already acted this turn', v_actor.name; END IF;$b$, 'act action check');
  v := pg_temp.rep(v, $a$          UPDATE public.rpg_sessions SET turn_beats = v_per WHERE id = v_s.id;$a$,
                      $b$          UPDATE public.rpg_sessions SET turn_action_ticks = public.rpg_action_ticks(p_actor_id, 1) WHERE id = v_s.id;$b$, 'act frightened');
  v := pg_temp.rep(v, $a$    UPDATE public.rpg_sessions SET turn_beats = turn_beats + v_beats WHERE id = v_s.id;$a$,
                      $b$    UPDATE public.rpg_sessions SET turn_action_ticks = public.rpg_action_ticks(p_actor_id, v_beats) WHERE id = v_s.id;$b$, 'act charge');
  v := pg_temp.rep(v, $a$'% already tried this round'$a$, $b$'% already tried this turn'$b$, 'act tried');
  EXECUTE v;
END $do$;

DO $do$
DECLARE v text := pg_get_functiondef('public.rpg_session_state(uuid)'::regprocedure);
BEGIN
  v := pg_temp.rep(v, $a$-- The board: its size, each square's movement penalty (terrain), where everyone stands, how far a beat of movement
-- takes each (rpg_move_per_beat), each weapon's and action's reach, and the squares the one whose turn it is can
-- still reach this turn ('moves', with what each costs and the beats that takes).$a$,
$b$-- The board: its size, each square's movement penalty (terrain), where everyone stands, each weapon's and action's
-- reach, and the squares the one whose turn it is can still reach this turn ('moves', with the path cost and ticks).
-- The fight clock: the tick now, each fighter's Speed and next tick (ticks_away: how soon they act; the list runs in
-- that order), each weapon's and action's ticks for that fighter (Karen's sword 36), and what the turn so far costs
-- (turn_cost: moving 13 and acting 27 is 33).$b$, 'state comment');
  v := pg_temp.rep(v, $a$'turn_beats', v_s.turn_beats, 'beats_per_turn', public.rpg_setting('beats_per_turn'), 'updated_at', v_s.updated_at$a$,
$b$'clock', v_s.clock, 'round_ticks', public.rpg_setting('round_ticks'), 'turn_move_ticks', v_s.turn_move_ticks,
                 'turn_action_ticks', v_s.turn_action_ticks, 'turn_cost', public.rpg_turn_cost(v_s.turn_move_ticks, v_s.turn_action_ticks),
                 'updated_at', v_s.updated_at$b$, 'state session');
  v := pg_temp.rep(v, $a$'terrain', v_s.terrain, 'turn_move_left', v_s.turn_move_left,$a$, $b$'terrain', v_s.terrain,$b$, 'state move left');
  v := pg_temp.rep(v, $a$'move_per_beat', public.rpg_move_per_beat(v_p.id)$a$,
                      $b$'speed', public.rpg_participant_speed(v_p.id), 'next_tick', v_p.next_tick, 'ticks_away', v_p.next_tick - v_s.clock$b$, 'state speed');
  v := pg_temp.rep(v, $a$'beats', d.beats, 'energy_cost'$a$, $b$'beats', d.beats, 'ticks', public.rpg_action_ticks(v_p.id, d.beats), 'energy_cost'$b$, 'state weapon ticks');
  v := pg_temp.rep(v, $a$'beats', a.beats, 'ready', a.ready,$a$,
                      $b$'beats', a.beats, 'ticks', CASE WHEN a.kind IN ('action', 'bonus_action') THEN public.rpg_action_ticks(v_p.id, a.beats) END, 'ready', a.ready,$b$, 'state action ticks');
  v := pg_temp.rep(v, $a$WHERE session_id = p_session_id ORDER BY turn_order, created_at LOOP$a$,
                      $b$WHERE session_id = p_session_id ORDER BY next_tick NULLS LAST, turn_order, created_at LOOP$b$, 'state order');
  EXECUTE v;
END $do$;

DO $do$
DECLARE v text := pg_get_functiondef('public.rpg_session_add(uuid,uuid,uuid)'::regprocedure);
BEGIN
  v := pg_temp.rep(v, $a$whoever joined first. The game
-- master's own moves stay. A creature$a$, $b$whoever joined first; that order breaks ties on the fight
-- clock. Joining a fight already on, the first turn comes one beat from now (Speed 7: 12 ticks). A creature$b$, 'add comment');
  v := pg_temp.rep(v, $a$  UPDATE public.rpg_session_participants SET turn_order = v_pos WHERE id = v_id;$a$,
$b$  UPDATE public.rpg_session_participants SET turn_order = v_pos WHERE id = v_id;
  IF v_s.status = 'active' THEN
    UPDATE public.rpg_session_participants SET next_tick = v_s.clock + public.rpg_action_ticks(v_id, 1) WHERE id = v_id;
  END IF;$b$, 'add clock');
  EXECUTE v;
END $do$;

CREATE OR REPLACE FUNCTION public.rpg_action_text(p_action_id uuid, p_skill numeric DEFAULT NULL::numeric)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One plain line for what a card's action does, built only from its row: the beats it takes as the creature's action
-- for a turn (actions only; a beat is 10 ticks at Speed 10, faster or slower by its Speed), its energy, its reach in
-- squares, the skill it rolls against which stat × the opponent multiplier, whether it does damage, and its effect.
-- With p_skill (a fight) the line carries the creature's number: "1 beat · 3 physical energy · Reach 1 square · Rolls
-- its Claw 10 against the target's Evade Enemy × 2 and does damage. A hit also rolls its Strength against the target's
-- Strength × 2; if that lands, the target is Knocked down and cannot act until their turn starts." A step (Rootstep)
-- says how far it goes (rpg_step_budget); a board action (Briar Shift) what it does to the ground. A revival rule (a
-- trait whose effect is on 'zero') gets its own line: "At 0 vitality it is Sunk and cannot act or be reached; after 2
-- rounds it rises with 1 vitality. A character ends it for good by rolling Healing (Spiritual) against its
-- Fascination with Evil × 2 (Sanctified)." So does a movement trait (Forest-Bound Terror). Other traits get no line.
-- An effect that exposes (Silenced, Judged) says who faces the target at × 1: every attacker, or the creature itself.
DECLARE
  a        public.rpg_creature_actions%ROWTYPE;
  v_names  jsonb;
  v_m      text := trim_scale(public.rpg_setting('opponent_will_multiplier'))::text;
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
    v_parts := v_parts || (a.beats || CASE WHEN a.beats = 1 THEN ' beat' ELSE ' beats' END);
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
    v_n := public.rpg_step_budget(coalesce((a.effect->>'beats')::integer, 1));
    v_parts := v_parts || ('Moves up to ' || v_n || CASE WHEN v_n = 1 THEN ' square' ELSE ' squares' END || ' of ground');
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

DROP FUNCTION IF EXISTS public.rpg_move_per_beat(uuid);
DROP FUNCTION IF EXISTS public.rpg_session_set_order(uuid, uuid[]);
ALTER TABLE public.rpg_sessions DROP COLUMN IF EXISTS turn_beats, DROP COLUMN IF EXISTS turn_move_left;

-- Fights already on join the clock where they stand: the round's first tick for the one whose turn it is now, one
-- beat later (at each fighter's own Speed) for everyone else.
DO $do$
BEGIN
  PERFORM set_config('rpg.engine', 'on', true);
  UPDATE public.rpg_sessions SET clock = (greatest(round, 1) - 1) * public.rpg_setting('round_ticks')::integer WHERE status = 'active';
  UPDATE public.rpg_session_participants p
     SET next_tick = s.clock + CASE WHEN p.id = s.current_participant_id THEN 0
                                    ELSE public.rpg_ticks_at(greatest(coalesce((public.rpg_sheet_values(p.character_id)->'values'->>'SP')::numeric, 0), 0),
                                                             public.rpg_setting('ticks_per_beat')) END
    FROM public.rpg_sessions s
   WHERE s.id = p.session_id AND s.status = 'active';
END $do$;

UPDATE public.rpg_rules SET body =
'Everyone in a fight acts on one fight clock, counted in ticks. Whoever''s next turn comes soonest goes; on a tie the faster one goes first, then the one with more Agility. When the fight starts, everyone''s first turn comes one beat in.
*The Bramblemaw (Speed 7) first acts at tick 12, Zaboo (Speed 5) at 13, Karen (Speed 1) at 18.*

Your Speed is (2 × Agility + Perception) ÷ 3, rounded down, and it sets how long everything takes: time = base × 20 ÷ (10 + Speed), rounded. A beat is 10 ticks at Speed 10.
*Karen: Agility 1, Perception 3, so Speed (2 + 3) ÷ 3 = 1. A sword swing is 2 beats (20 base): 20 × 20 ÷ 11 = 36 ticks for her, 27 for Zaboo. The Bramblemaw''s Claw is 1 beat: 10 × 20 ÷ 17 = 12 ticks.*

On your turn you may move and take one action (an attack, a card action, Rest or Defend), then end your turn. Your next turn comes after the time it took. Moving and acting together cost the bigger of the two plus half the smaller. Ending a turn having done neither costs one beat of waiting.
*Zaboo walks 2 squares (13 ticks) and swings (27): 27 + 6 = 33 ticks, so her next turn is 33 ticks from now.*

A fast fighter spends less time on each turn, so it can act more than once before a slow one acts at all. The Bramblemaw claws every 12 ticks while Karen swings every 36: three of its turns to one of hers.

A round is 20 ticks. When a new round begins, anyone Held from an earlier round is free, everyone regains energy, and creatures get their legendary actions back (Bramblemaw has 3).

Someone who cannot act (down, asleep, held, knocked down) is easier to hit. Their difficulty is their skill × 1 instead of × 2: Evade Enemy 5 is difficulty 5 instead of 10, so an attacker with skill 5 needs 50 instead of 67.

Before you attack, shake off what is on you. Frightened by Briar Roar: roll Courage against 8 once each turn (Courage 7 needs 54 or more). Pass and it is gone; fail and you cannot attack this turn. Held by Grasping Roots ends when the next round begins. Knocked down by a Claw ends when your turn starts: you get up and act.

A creature''s legendary actions come from a roll: at the end of anyone else''s turn the site rolls a six-sided die for it, and on 4 or more it spends one on its best ready move (Rending Swipe: a sweep at everyone next to it; Rootstep: a step toward someone), up to its number a round.'
WHERE key = 'turn_order';

DO $do$
DECLARE v text;
BEGIN
  SELECT body INTO v FROM public.rpg_rules WHERE key = 'energy';
  v := pg_temp.rep(v, $a$The pools refill at the start of your turn by your regain.$a$, $b$The pools refill by your regain each time a new round begins (every 20 ticks).$b$, 'energy refill');
  v := pg_temp.rep(v, $a$regains Endurance ÷ 2 a turn$a$, $b$regains Endurance ÷ 2 a round$b$, 'energy regain');
  v := pg_temp.rep(v, $a$Rest takes the whole turn and gives one more regain on top. Defend takes the whole turn:$a$,
                      $b$Rest is your action for the turn (2 beats: 20 ticks at Speed 10, 36 for Karen) and gives one more regain on top. Defend is your action for the turn (2 beats):$b$, 'energy rest');
  UPDATE public.rpg_rules SET body = v WHERE key = 'energy';
  SELECT body INTO v FROM public.rpg_rules WHERE key = 'moving';
  v := pg_temp.rep(v, $a$One beat of movement takes you 1 + your Agility ÷ 3 squares, rounded down.
*Karen, Agility 1: 1 + 0 = 1 square a beat, 2 in a whole turn. The Bramblemaw, Agility 7: 1 + 2 = 3 squares a beat.*

Every square has a movement penalty from 0 to 9. Stepping into a square costs 1 plus its penalty, and a diagonal step costs the same as a straight one. Movement you paid a beat for and did not use stays yours until your turn ends.
*Briars with penalty 2 cost 3 to step into. That is 3 beats for Karen, more than a turn holds, so she goes around. The Bramblemaw crosses in one beat.*$a$,
$b$Moving takes time on the fight clock: a plain square is 5 ticks at Speed 10, faster or slower by your Speed like everything else (time = base × 20 ÷ (10 + Speed)). A turn holds up to 20 ticks of moving.
*Zaboo (Speed 5) walks 2 plain squares in 10 × 20 ÷ 15 = 13 ticks and 3 in 20. Karen (Speed 1) walks 2 in 18. The Bramblemaw (Speed 7) walks 3 in 18.*

Every square has a movement penalty from 0 to 9. Stepping into a square costs 1 plus its penalty, and a diagonal step costs the same as a straight one.
*Briars with penalty 2 cost 3 to step into: 15 ticks at Speed 10, 27 for Karen, more than a turn holds, so she goes around. The Bramblemaw ignores movement penalties.*$b$, 'moving body');
  UPDATE public.rpg_rules SET body = v WHERE key = 'moving';
END $do$;

REVOKE ALL ON FUNCTION public.rpg_ticks_at(numeric, numeric), public.rpg_participant_speed(uuid), public.rpg_action_ticks(uuid, numeric),
  public.rpg_turn_cost(integer, integer), public.rpg_step_budget(integer), public.rpg_move_budget(uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_ticks_at(numeric, numeric), public.rpg_participant_speed(uuid), public.rpg_action_ticks(uuid, numeric),
  public.rpg_turn_cost(integer, integer), public.rpg_step_budget(integer), public.rpg_move_budget(uuid, integer) TO service_role;

DO $do$
BEGIN
  IF NOT has_function_privilege('authenticated', 'public.rpg_act(uuid,uuid[],text,uuid,text,numeric,integer,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpg_session_next_turn(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpg_session_auto_turn(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpg_session_state(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpg_session_add(uuid,uuid,uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpg_act_square(uuid,integer,integer,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'a fight function lost its grant';
  END IF;
  IF has_function_privilege('authenticated', 'public.rpg_action_ticks(uuid,numeric)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.rpg_move_options(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'an internal fight function is open to players';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname LIKE 'rpg_%'
              AND prosrc ~ '(beats_per_turn|turn_beats|turn_move_left|move_per_beat|move_agility_divisor)') THEN
    RAISE EXCEPTION 'a function still reads the old turn';
  END IF;
END $do$;

