-- Weather step 2b (Peter 2026-10-09): weather in fights: moving, fire and shots in the wind.

CREATE OR REPLACE FUNCTION public.rpg_map_weather_fight(p_kind text)
 RETURNS TABLE(wet boolean, wind boolean) LANGUAGE sql IMMUTABLE
AS $fn$
-- What a kind of weather does in a fight (weather step 2b, Peter 2026-10-09), the one list of it beside rpg_map_weathers:
-- wet = rain, a thunderstorm, snow or a blizzard soak what would burn, so a square set alight does not catch (fuel
-- holding more than about a third of its weight in water does not carry a flame: the moisture of extinction of fine
-- fuels, Rothermel 1972); wind = a thunderstorm, a blizzard (winds of 35 miles an hour or more, US National Weather
-- Service) or a dust storm blow a shot off its mark from 2 squares away or more, and a dust storm (hot, dry and windy)
-- keeps a fire burning a round longer. Clear, cloudy and fog do neither.
SELECT coalesce(p_kind IN ('rain', 'storm', 'snow', 'blizzard'), false), coalesce(p_kind IN ('storm', 'blizzard', 'dust'), false);
$fn$;
REVOKE ALL ON FUNCTION public.rpg_map_weather_fight(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpg_map_weather_fight(text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.rpg_fight_weather(p_session_id uuid, p_x integer, p_y integer)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $fn$
-- The weather over a square of a fight (world squares from 1, as pieces stand; weather step 2b), the one home of it:
-- the map's weather there at the journey clock (rpg_map_weather_here: kind, name, walk_pct, sight), or nothing under the
-- ground, up or down a house (rpg_fight_layer) or inside a building (rpg_map_building_squares). Read by rpg_grid_costs
-- (moving), rpg_cover (shots in the wind) and rpg_ignite (fire).
SELECT CASE WHEN l.under_at IS NULL AND coalesce(l.floor, 0) = 0
                 AND NOT EXISTS (SELECT 1 FROM public.rpg_map_building_squares(7, p_x - 1, p_y - 1, 1, 1, false))
            THEN public.rpg_map_weather_here(p_x - 1, p_y - 1, coalesce(s.clock, 0)) END
  FROM public.rpg_sessions s
  LEFT JOIN LATERAL public.rpg_fight_layer(s.id, p_x, p_y) l ON true
 WHERE s.id = p_session_id AND s.on_map;
$fn$;
REVOKE ALL ON FUNCTION public.rpg_fight_weather(uuid, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_fight_weather(uuid, integer, integer) TO service_role;
CREATE OR REPLACE FUNCTION public.rpg_grid_costs(p_participant_id uuid, p_budget integer)
 RETURNS TABLE(x integer, y integer, cost integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What it costs this fighter to reach each square within p_budget of path cost from where they stand, in hundredths of
-- a plain square. Stepping into a square costs 100 plus the percent of time it adds (just 100 for a creature whose
-- card says the ground never slows it: rpg_participant_ignores_penalty), plus burn_cost (300) while the square burns,
-- for everyone, plus the weather's percent where the fighter stands (weather step 2b, rpg_fight_weather); a diagonal step costs the same as a straight one; nobody steps into the sea or into a square someone
-- takes up on the same floor (rpg_participant_blocks; storeys step: someone on another floor of a house is not in the way). The first step of a turn may always be taken, whatever it costs, by the one whose
-- turn it is before they have moved (a thicket or a mountain square can take longer than a whole turn of moving; that
-- turn then takes that long). The ground is the world map under the fight (rpg_fight_squares), read once for the block
-- round the fighter. Squares nobody can get to are left out. From C3, briars at +260% on D3 cost 360 to enter, and a
-- plain E3 past them 460; burning briars cost 660, and the Bramblemaw pays 400 there.
DECLARE
  v_p record; v_s record; v_b integer := greatest(coalesce(p_budget, 0), 0); x0 integer; y0 integer; w integer; h integer; n integer;
  d integer[]; pen integer[]; fire integer[]; blk boolean[]; v_ign boolean; v_changed boolean; v_big constant integer := 1000000;
  i integer; j integer; cx integer; cy integer; dx integer; dy integer; nx integer; ny integer; c integer; v_q record; v_o record;
  v_burn integer := public.rpg_setting('burn_cost')::integer; v_down integer; v_first boolean; v_r integer; v_wpct integer := 0;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.pos_x IS NULL THEN RETURN; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id;
  IF NOT v_s.on_map THEN RETURN; END IF;
  -- the first step of a turn may always be taken, whatever it costs, by the one whose turn it is before they have moved
  v_first := v_s.current_participant_id IS NOT DISTINCT FROM p_participant_id AND coalesce(v_s.turn_move_ticks, 0) = 0;
  IF v_b = 0 AND NOT v_first THEN RETURN; END IF;
  -- squares, not cost: the block round the fighter reaches as far as the budget goes on plain ground (100 a square)
  v_r := greatest(v_b / 100, 1);
  SELECT l.span / 2 INTO v_down FROM public.rpg_map_ladder() l WHERE l.level = 1;
  x0 := greatest(v_p.pos_x - v_r, 1); w := least(v_p.pos_x + v_r, v_down * 2) - x0 + 1;
  y0 := greatest(v_p.pos_y - v_r, 1); h := least(v_p.pos_y + v_r, v_down) - y0 + 1;
  n := w * h;
  v_ign := public.rpg_participant_ignores_penalty(p_participant_id);
  -- (weather step 2b) the weather where the fighter stands adds its percent to every step, ground or no ground, as on a
  -- walk (rpg_fight_weather: rain +10%, a blizzard +100%; nothing indoors or under the ground)
  v_wpct := coalesce((public.rpg_fight_weather(v_s.id, v_p.pos_x, v_p.pos_y) ->> 'walk_pct')::integer, 0);
  d := array_fill(v_big, ARRAY[n]); pen := array_fill(0, ARRAY[n]); fire := array_fill(0, ARRAY[n]); blk := array_fill(false, ARRAY[n]);
  FOR v_q IN SELECT * FROM public.rpg_fight_squares(v_s.id, x0, y0, w, h) LOOP
    i := (v_q.y - y0) * w + (v_q.x - x0) + 1;
    IF v_q.sea THEN blk[i] := true; ELSE pen[i] := v_q.penalty; END IF;
    fire[i] := CASE WHEN v_q.burning THEN v_burn ELSE 0 END;
  END LOOP;
  FOR v_o IN SELECT o.pos_x, o.pos_y FROM public.rpg_session_participants o
              WHERE o.session_id = v_p.session_id AND o.id <> v_p.id AND o.floor = v_p.floor AND public.rpg_participant_blocks(o.id) LOOP
    IF v_o.pos_x BETWEEN x0 AND x0 + w - 1 AND v_o.pos_y BETWEEN y0 AND y0 + h - 1 THEN blk[(v_o.pos_y - y0) * w + (v_o.pos_x - x0) + 1] := true; END IF;
  END LOOP;
  d[(v_p.pos_y - y0) * w + (v_p.pos_x - x0) + 1] := 0;
  LOOP
    v_changed := false;
    FOR i IN 1..n LOOP
      CONTINUE WHEN d[i] >= v_big;
      cx := (i - 1) % w; cy := (i - 1) / w;
      FOR dx IN -1..1 LOOP
        FOR dy IN -1..1 LOOP
          nx := cx + dx; ny := cy + dy;
          CONTINUE WHEN (dx = 0 AND dy = 0) OR nx < 0 OR ny < 0 OR nx >= w OR ny >= h;
          j := ny * w + nx + 1;
          CONTINUE WHEN blk[j];
          c := d[i] + 100 + CASE WHEN v_ign THEN 0 ELSE pen[j] END + v_wpct + fire[j];
          IF c < d[j] AND (c <= v_b OR (v_first AND d[i] = 0)) THEN d[j] := c; v_changed := true; END IF;
        END LOOP;
      END LOOP;
    END LOOP;
    EXIT WHEN NOT v_changed;
  END LOOP;
  RETURN QUERY SELECT x0 + (k - 1) % w, y0 + (k - 1) / w, d[k] FROM generate_subscripts(d, 1) AS k WHERE d[k] < v_big;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.rpg_ignite(p_session_id uuid, p_x integer, p_y integer)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Sets one square alight for burn_rounds (3) rounds (weather step 2b: not in rain, a thunderstorm, snow or a blizzard;
-- a round longer in a dust storm) and burns whoever waits there under a revival rule that fire ends
-- (rpg_burn_out: a Sunk Bramblemaw). Returns the log tail. Internal: rpg_act_square (a Torch) and rpg_set_square (fire by hand).
DECLARE v_s record; v_until integer; v_text text; v_p record; v_w jsonb; v_wet boolean; v_wind boolean;
BEGIN
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  -- (weather step 2b) the weather over the square (rpg_fight_weather, rpg_map_weather_fight): rain, a thunderstorm, snow
  -- or a blizzard keep it from catching; a dust storm keeps it burning a round longer
  v_w := public.rpg_fight_weather(p_session_id, p_x, p_y);
  SELECT f.wet, f.wind INTO v_wet, v_wind FROM public.rpg_map_weather_fight(v_w ->> 'kind') f;
  IF v_wet THEN
    RETURN ' The ' || lower(v_w ->> 'name') || ' keeps ' || public.rpg_square_name(p_x, p_y) || ' from catching.';
  END IF;
  v_until := coalesce(v_s.round, 1) + public.rpg_setting('burn_rounds')::integer + CASE WHEN v_w ->> 'kind' = 'dust' THEN 1 ELSE 0 END;
  PERFORM public.rpg_square_set(p_session_id, p_x, p_y, NULL, NULL, v_until);
  v_text := ' ' || public.rpg_square_name(p_x, p_y) || ' burns until round ' || v_until || '.';
  FOR v_p IN SELECT p.id FROM public.rpg_session_participants p WHERE p.session_id = p_session_id AND p.pos_x = p_x AND p.pos_y = p_y LOOP
    v_text := v_text || coalesce(public.rpg_burn_out(v_p.id), '');
  END LOOP;
  RETURN v_text;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.rpg_cover(p_attacker uuid, p_target uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The cover a target has from an attacker on the fight grid (step 14f-battle, Peter 2026-10-08 18:52, 1A), the one
-- home of it: what lies on the square right beside the target on the way to the attacker, the first square the
-- straight line from the target to the attacker passes (target C3, attacker H5: 5 across and 2 down, so one across
-- and 2/5 of one down, rounded: D3), read on the world map under the fight (rpg_fight_square, rpg_map_lie):
-- 'full' behind a boulder, 'half' behind a fallen log, 'wind' in a wind that blows a shot off its mark (weather step
-- 2b), null otherwise. Only from two squares or more away: a blow
-- from the square beside reaches over. Read by rpg_act: a physical blow cannot be aimed past full cover, and a blow
-- that lands on half cover strikes the log when its die is in the lower half of the dice that land.
SELECT coalesce(CASE (SELECT f.lie FROM public.rpg_sessions s
              CROSS JOIN LATERAL public.rpg_fight_square(s.id, t.pos_x + round(sign(a.pos_x - t.pos_x) * least(abs(a.pos_x - t.pos_x)::numeric / greatest(abs(a.pos_x - t.pos_x), abs(a.pos_y - t.pos_y)), 1))::integer,
                                                       t.pos_y + round(sign(a.pos_y - t.pos_y) * least(abs(a.pos_y - t.pos_y)::numeric / greatest(abs(a.pos_x - t.pos_x), abs(a.pos_y - t.pos_y)), 1))::integer) f
             WHERE s.id = t.session_id)
         WHEN 'boulder' THEN 'full' WHEN 'log' THEN 'half' END,
         -- (weather step 2b) 'wind': in a thunderstorm, a blizzard or a dust storm where the attacker stands
         -- (rpg_fight_weather, rpg_map_weather_fight) a blow that lands from 2 squares away or more is blown off its mark
         -- when its die is in the lower half of the dice that land, the same as half cover
         CASE WHEN (SELECT w.wind FROM public.rpg_map_weather_fight(public.rpg_fight_weather(a.session_id, a.pos_x, a.pos_y) ->> 'kind') w) THEN 'wind' END)
  FROM public.rpg_session_participants a, public.rpg_session_participants t
 WHERE a.id = p_attacker AND t.id = p_target AND a.pos_x IS NOT NULL AND t.pos_x IS NOT NULL
   AND public.rpg_square_gap(a.pos_x, a.pos_y, t.pos_x, t.pos_y) >= 2;
$function$
;
CREATE OR REPLACE FUNCTION public.rpg_act(p_actor_id uuid, p_target_ids uuid[] DEFAULT NULL::uuid[], p_stat_key text DEFAULT NULL::text, p_action_id uuid DEFAULT NULL::uuid, p_against text DEFAULT NULL::text, p_difficulty numeric DEFAULT NULL::numeric, p_roll integer DEFAULT NULL::integer, p_effect text DEFAULT NULL::text, p_card uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One move in a fight, by the one whose turn it is. Every roll goes through rpg_roll, from the sheet of the roller.
--   REST / DEFEND (p_stat_key) take the whole turn: Rest gives one more regain; Defend puts "Defending" on you until
--   your next turn so rolls against you face your skill × 3 (rpg_difficulty).
--   Anyone rolls from their own sheet (p_stat_key): a weapon skill at one target is an attack; any stat at targets
--   with p_against rolls against that stat of theirs; with no target it is a check. A creature also uses the actions
--   on its card, each rolling one of its own skills by skill_key (the Bramblemaw's Claw rolls its sheet's Claw 10).
--   A creature is a character made from its card, so its sheet, its Integrity and its energy work like yours.
--   Attacks and actions cost time on the fight clock (rpg_action_ticks; one action a turn) and energy (energy_cost of that energy_type); a move you cannot pay
--   for is refused. Every roll at a target must reach it on the fight grid (rpg_in_reach): Claw 1 square, Briar Roar
--   6, Longbow 12, counted as the larger gap across or up-down; someone not on the board is always in reach. A card
--   action that is not an area action aims at one target. A target hidden by its ground (Forest-Bound Terror on
--   forest: unseen beyond 2 squares) is out of reach past that distance whatever the weapon (rpg_reach_to). Every
--   hostile roll marks the actor as having attacked, and a Judged actor who strikes at an innocent is Condemned
--   (rpg_judgement). A card action may come from a thing the fighter holds (rpg_participant_cards).
--   An attack runs three gates (rule card "Land, Block, Hit"). Land: the skill against the target's evade × 2
--   (rpg_difficulty; evade lowered by rpg_participant_burden). Under the still-target line is a Miss, above it Evaded.
--   Cover (rpg_cover; step 14f-battle): a physical blow is refused at someone behind a boulder, and one that lands on
--   someone behind a fallen log strikes the log (Blocked) when its die is in the lower half of the dice that land.
--   Knowledge (rpg_knows) counts both ways: the actor's Knowing <the target's card> goes into rpg_roll, the target's
--   Knowing <the actor's card> adds to the stat it defends with (evade, block, a contest) before the × 2, and the log
--   names both. p_card is the card a no-target check is about (studying a Bramblemaw).
--   Block: someone holding a shield or weapon blocks with Block + the item's block, × 2; a spiritual attack that
--   lands an effect is blocked by the Shield of Faith. Fail = Blocked; the blocking item takes the blow's damage
--   (rpg_item_damage) and the weapon a fifth of it. Hit: rpg_damage minus what worn armor absorbs (the armor takes
--   that; the weapon a fifth); what is left must clear the target's Integrity. An attack on the heart or the mind (the
--   card's "aim") is absorbed by the armor piece that guards it (rpg_stat_definitions.guards: the Breastplate of
--   Righteousness, the Helmet of Salvation) up to its own value, which wears by that much; only what is left puts
--   the effect on (rpg_armor_state, rpg_armor_wear). A landed effect goes on the target as
--   the card says (Briar Roar → Frightened; a Claw hit → Strength contest → Knocked down). Legendary actions may be
--   used on other turns by the game master or the rules engine (rpg.engine). A check a rule demands (p_effect) comes
--   before an attack. p_roll is a die rolled by hand: a manual critical waits for rpg_act_extra.
DECLARE
  v_gm boolean := public.family_is_parent() OR coalesce(current_setting('rpg.engine', true), '') = 'on';
  v_actor record; v_s record; v_act record; v_use record; v_t record; v_item record; v_actor_card uuid; v_target_card uuid; v_know_def numeric := 0; v_know_txt text := '';
  v_targets uuid[] := coalesce(p_target_ids, '{}'::uuid[]);
  v_kind text; v_key text; v_label text; v_against text; v_against_name text;
  v_damage_ok boolean := false; v_is_attack boolean := false; v_stat_name text; v_spirit_fx boolean := false; v_discipline boolean := false; v_shield jsonb; v_piece jsonb; v_turned boolean := false; v_strength integer;
  v_tid uuid; v_cid uuid; v_rev jsonb; v_ending boolean := false; v_def numeric; v_diff numeric; v_diff_still numeric; v_roll jsonb; v_first jsonb; v_extras integer[]; v_i integer;
  v_dmg integer; v_net integer; v_vit jsonb; v_text text; v_needs integer; v_results jsonb := '[]'::jsonb; v_levelup text;
  v_eff jsonb; v_fx jsonb; v_out jsonb; v_pending boolean; v_tail text; v_who text; v_xtext text;
  v_croll jsonb; v_cdiff numeric;
  v_plan jsonb := '[]'::jsonb; v_step jsonb; v_e jsonb; v_n integer; v_beats integer := 0;
  v_ecost integer := 0; v_etype text := 'physical'; v_energy jsonb; v_defending boolean;
  v_cover text;
  v_blk numeric; v_blocker uuid; v_blocker_name text; v_broll jsonb; v_blocked boolean; v_absorb integer; v_wear jsonb; v_weapon uuid; v_integrity integer; v_bounced boolean; v_reach integer; v_rname text; v_area boolean;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  PERFORM set_config('rpg.move', 'on', true);
  SELECT * INTO v_actor FROM public.rpg_session_participants WHERE id = p_actor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  SELECT template_id INTO v_actor_card FROM public.rpg_characters WHERE id = v_actor.character_id;
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
  -- Reach on the fight grid: the card action's reach, or the rolled skill's.
  IF p_effect IS NULL AND cardinality(v_targets) > 0 THEN
    IF p_action_id IS NOT NULL THEN
      SELECT reach, name, area INTO v_reach, v_rname, v_area FROM public.rpg_creature_actions WHERE id = p_action_id;
      IF cardinality(v_targets) > 1 AND NOT coalesce(v_area, false) THEN RAISE EXCEPTION '% aims at one target', v_rname; END IF;
    ELSE
      SELECT reach, name INTO v_reach, v_rname FROM public.rpg_stat_definitions WHERE key = p_stat_key;
    END IF;
    FOR v_tid IN SELECT unnest(v_targets) LOOP
      IF NOT public.rpg_in_reach(p_actor_id, v_tid, coalesce(v_reach, 1)) THEN
        -- (storeys step) a floor or a ceiling between them
        IF EXISTS (SELECT 1 FROM public.rpg_session_participants t WHERE t.id = v_tid AND t.pos_x IS NOT NULL AND t.floor IS DISTINCT FROM v_actor.floor) THEN
          RAISE EXCEPTION '% is on another floor: nothing reaches between floors', (SELECT name FROM public.rpg_session_participants WHERE id = v_tid);
        END IF;
        IF public.rpg_reach_to(v_tid, coalesce(v_reach, 1)) < coalesce(v_reach, 1) THEN
          RAISE EXCEPTION '% is unseen in the forest beyond % squares and stands % away', (SELECT name FROM public.rpg_session_participants WHERE id = v_tid),
            public.rpg_reach_to(v_tid, coalesce(v_reach, 1)), public.rpg_distance(p_actor_id, v_tid);
        END IF;
        RAISE EXCEPTION '% is % squares away and % reaches %', (SELECT name FROM public.rpg_session_participants WHERE id = v_tid),
          public.rpg_distance(p_actor_id, v_tid), coalesce(v_rname, 'that roll'), coalesce(v_reach, 1);
      END IF;
    END LOOP;
  END IF;
  -- A creature at 0 vitality is out of reach: dead, or waiting under its card's revival rule, when only the roll
  -- that rule names reaches it (Sunk → Healing (Spiritual) against its Fascination with Evil).
  FOR v_tid IN SELECT unnest(v_targets) LOOP
    SELECT * INTO v_t FROM public.rpg_session_participants WHERE id = v_tid;
    CONTINUE WHEN v_t.creature_id IS NULL OR (public.rpg_participant_vitality(v_tid)->>'left')::integer > 0;
    v_rev := NULL;
    SELECT e INTO v_rev FROM jsonb_array_elements(v_t.effects) e WHERE e ? 'ended_by' LIMIT 1;
    IF v_rev IS NULL THEN RAISE EXCEPTION '% is dead', v_t.name; END IF;
    IF p_stat_key IS DISTINCT FROM v_rev->'ended_by'->>'skill_key' OR p_against IS DISTINCT FROM v_rev->'ended_by'->>'against' THEN
      RAISE EXCEPTION '% is %: only % against its % reaches it', v_t.name, v_rev->>'name',
        (SELECT name FROM public.rpg_stat_definitions WHERE key = v_rev->'ended_by'->>'skill_key'),
        (SELECT name FROM public.rpg_stat_definitions WHERE key = v_rev->'ended_by'->>'against');
    END IF;
    v_ending := true;
  END LOOP;
  v_energy := public.rpg_participant_energy(p_actor_id);

  -- Rest and Defend: the whole turn.
  IF p_stat_key IN ('REST', 'DEFEND') THEN
    IF v_s.current_participant_id IS DISTINCT FROM p_actor_id THEN RAISE EXCEPTION 'it is not %''s turn', v_actor.name; END IF;
    IF v_s.turn_action_ticks > 0 THEN RAISE EXCEPTION '% has already acted this turn', v_actor.name; END IF;
    IF p_stat_key = 'REST' THEN
      UPDATE public.rpg_session_participants SET energy_used_physical = greatest(energy_used_physical - (v_energy->'physical'->>'regain')::integer, 0),
             energy_used_spiritual = greatest(energy_used_spiritual - (v_energy->'spiritual'->>'regain')::integer, 0) WHERE id = p_actor_id;
      v_text := v_actor.name || ' rests and regains ' || (v_energy->'physical'->>'regain') || ' physical and ' || (v_energy->'spiritual'->>'regain') || ' spiritual energy.';
    ELSE
      PERFORM public.rpg_participant_apply_effect(p_actor_id, '{"name": "Defending", "cannot_act": false, "clear": "turn_start", "defend": true}'::jsonb, 'Defend', v_s.round);
      v_text := v_actor.name || ' defends: until ' || CASE WHEN v_actor.creature_id IS NULL THEN 'their' ELSE 'its' END || ' next turn, rolls against ' || CASE WHEN v_actor.creature_id IS NULL THEN 'them' ELSE 'it' END || ' face evade × ' || trim_scale(public.rpg_setting('defend_multiplier')) || '.';
    END IF;
    UPDATE public.rpg_sessions SET turn_action_ticks = public.rpg_action_ticks(p_actor_id, public.rpg_setting('rest_beats')), updated_at = now() WHERE id = v_s.id;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, v_s.id, v_s.round, 'action', 'info', p_actor_id, v_text);
    RETURN jsonb_build_object('kind', lower(p_stat_key), 'label', initcap(lower(p_stat_key)), 'results', jsonb_build_array(jsonb_build_object('outcome', 'info', 'text', v_text)));
  END IF;

  IF p_effect IS NOT NULL THEN
    SELECT e INTO v_eff FROM jsonb_array_elements(v_actor.effects) e WHERE e->>'name' = p_effect AND e->>'clear' = 'check';
    IF v_eff IS NULL THEN RAISE EXCEPTION '% is not % right now', v_actor.name, p_effect; END IF;
    IF (v_eff->>'checked_round')::integer = v_s.round THEN RAISE EXCEPTION '% already tried this turn', v_actor.name; END IF;
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
      IF v_s.turn_action_ticks > 0 THEN RAISE EXCEPTION '% has already acted this turn', v_actor.name; END IF;
      IF (v_energy->v_etype->>'left')::integer < v_ecost THEN RAISE EXCEPTION '% has % % energy left and % costs %', v_actor.name, v_energy->v_etype->>'left', v_etype, v_stat_name, v_ecost; END IF;
      SELECT e->>'name' INTO v_who FROM jsonb_array_elements(v_actor.effects) e
       WHERE e->>'clear' = 'check' AND (e->>'checked_round')::integer IS DISTINCT FROM v_s.round LIMIT 1;
      IF v_who IS NOT NULL THEN RAISE EXCEPTION '% must shake off % first', v_actor.name, v_who; END IF;
      v_kind := 'attack'; v_against := 'EE'; v_damage_ok := true;
      -- the weapon: an unbroken held item whose card is swung with this skill (its object takes a fifth of what it strikes)
      v_weapon := (public.rpg_weapon_bulk(v_actor.character_id, p_stat_key)->>'item_id')::uuid;
    ELSIF cardinality(v_targets) > 0 THEN
      v_kind := 'check'; v_against := p_against;
      IF v_ending THEN
        IF v_s.turn_action_ticks > 0 THEN RAISE EXCEPTION '% has already acted this turn', v_actor.name; END IF;
        IF (v_energy->v_etype->>'left')::integer < coalesce(v_ecost, 0) THEN RAISE EXCEPTION '% has % % energy left and % costs %', v_actor.name, v_energy->v_etype->>'left', v_etype, v_stat_name, v_ecost; END IF;
      ELSE
        v_beats := 0; v_ecost := 0;
      END IF;
    ELSE
      v_kind := 'check';
      v_diff := greatest(coalesce(p_difficulty, public.rpg_setting('default_difficulty')), 0);
      -- Prayer and Bible Study in a fight: your own turn's action, paid from spiritual energy (rpg_roll adds the burden to the difficulty)
      SELECT coalesce(d.spirit_discipline, false) INTO v_discipline FROM public.rpg_stat_definitions d WHERE d.key = p_stat_key;
      IF v_discipline THEN
        IF v_s.current_participant_id IS DISTINCT FROM p_actor_id THEN RAISE EXCEPTION 'it is not %''s turn', v_actor.name; END IF;
        IF v_s.turn_action_ticks > 0 THEN RAISE EXCEPTION '% has already acted this turn', v_actor.name; END IF;
        IF (v_energy->v_etype->>'left')::integer < v_ecost THEN RAISE EXCEPTION '% has % % energy left and % costs %', v_actor.name, v_energy->v_etype->>'left', v_etype, v_stat_name, v_ecost; END IF;
      ELSE
        v_beats := 0; v_ecost := 0;
      END IF;
    END IF;
  ELSE
    SELECT * INTO v_act FROM public.rpg_creature_actions WHERE id = p_action_id AND creature_id = ANY (public.rpg_participant_cards(p_actor_id));
    IF NOT FOUND THEN RAISE EXCEPTION 'that action is not on this fighter''s card or on a thing they hold'; END IF;
    IF v_act.kind = 'trait' THEN RAISE EXCEPTION '% is a trait, not an action', v_act.name; END IF;
    IF v_act.kind = 'lair' AND v_actor.lair_round IS NOT DISTINCT FROM v_s.round THEN RAISE EXCEPTION '% has used its lair this round', v_actor.name; END IF;
    IF v_act.kind = 'legendary' AND v_actor.legendary_left < v_act.legendary_cost THEN
      RAISE EXCEPTION '% has % legendary actions left and % costs %', v_actor.name, v_actor.legendary_left, v_act.name, v_act.legendary_cost;
    END IF;
    IF NOT public.rpg_action_ready(p_actor_id, v_act.id) THEN
      RAISE EXCEPTION '% has % % energy left and % costs %', v_actor.name, v_energy->v_act.energy_type->>'left', v_act.energy_type, v_act.name, v_act.energy_cost;
    END IF;
    IF v_act.kind IN ('action', 'bonus_action') AND v_s.current_participant_id = p_actor_id THEN
      IF v_s.turn_action_ticks > 0 THEN RAISE EXCEPTION '% has already acted this turn', v_actor.name; END IF;
      v_beats := v_act.beats;
    END IF;
    v_ecost := v_act.energy_cost; v_etype := v_act.energy_type;
    v_kind := 'action'; v_label := v_act.name;
    IF v_act.skill_key IS NOT NULL THEN
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
    IF v_act.effect->>'on' IN ('step', 'board') THEN RAISE EXCEPTION 'choose a square on the board for %', v_act.name; END IF;
    IF v_act.effect->>'on' = 'self' THEN
      PERFORM public.rpg_participant_apply_effect(p_actor_id, v_act.effect->'apply', v_act.name, v_s.round);
    END IF;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, v_s.id, v_s.round, 'action', 'info', p_actor_id, v_actor.name || ' uses ' || v_act.name || '.'
            || CASE WHEN v_act.effect->>'on' = 'self' THEN ' It is ' || (v_act.effect->'apply'->>'name') || '.' ELSE '' END);
  ELSIF cardinality(v_targets) = 0 THEN
    v_roll := public.rpg_roll(v_actor.character_id, v_key, v_diff, v_label, NULL, v_s.id, p_actor_id, p_roll, p_card);
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
    v_tail := coalesce(' ' || nullif(v_first->'discipline'->>'text', ''), '');
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
          UPDATE public.rpg_sessions SET turn_action_ticks = public.rpg_action_ticks(p_actor_id, 1) WHERE id = v_s.id;
          v_tail := ' ' || v_actor.name || ' stays ' || p_effect || ' and cannot attack this turn.';
        ELSE
          v_tail := ' ' || v_actor.name || ' stays ' || p_effect || '.';
        END IF;
      END IF;
    END IF;
    v_xtext := CASE WHEN cardinality(v_extras) > 0 THEN ' Extra roll' || CASE WHEN cardinality(v_extras) > 1 THEN 's ' ELSE ' ' END || array_to_string(v_extras, ' and ') || '.' ELSE '' END;
    v_text := (v_out->>'label') || ': ' || v_actor.name || ' rolls ' || v_label || CASE WHEN coalesce((v_first->'knowledge'->>'value')::numeric, 0) > 0 THEN ' (' || (v_first->'knowledge'->>'name') || ' ' || trim_scale((v_first->'knowledge'->>'value')::numeric) || ')' ELSE '' END || CASE WHEN coalesce((v_first->'place_knowledge'->>'value')::numeric, 0) > 0 THEN ' (' || (v_first->'place_knowledge'->>'name') || ' ' || trim_scale((v_first->'place_knowledge'->>'value')::numeric) || ')' ELSE '' END || ' against ' || trim_scale(v_diff) || CASE WHEN v_discipline AND (v_first->>'difficulty')::numeric > v_diff THEN ' + ' || trim_scale((v_first->>'difficulty')::numeric - v_diff) || ' burden' ELSE '' END
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
      -- knowledge both ways (rpg_knows): the target's Knowing <the actor's card> adds to what it defends with; the actor's Knowing <the target's card> goes into rpg_roll
      SELECT template_id INTO v_target_card FROM public.rpg_characters WHERE id = v_t.character_id;
      v_know_def := public.rpg_knows(v_t.character_id, v_actor_card);
      -- Gate 1: land. Evade lowered by burden.
      v_def := greatest(coalesce(public.rpg_participant_value(v_tid, v_against), 0)
                        - CASE WHEN v_against IN ('EE', 'BGP') THEN public.rpg_participant_burden(v_tid, CASE WHEN v_against = 'BGP' THEN 'spiritual' ELSE 'physical' END) ELSE 0 END, 0) + v_know_def;
      v_diff := public.rpg_difficulty(v_def, public.rpg_participant_can_act(v_tid) AND NOT (v_against IN ('EE', 'BGP') AND public.rpg_participant_exposed(v_tid, p_actor_id)), v_defending);
      -- The roll that ends a revival rule faces the creature's stat × 2, as if it could act.
      IF v_ending THEN v_diff := public.rpg_difficulty(v_def, true, false); END IF;
      v_diff_still := public.rpg_difficulty(v_def, false);
      -- (step 14f-battle) cover (rpg_cover): no physical blow is aimed at someone behind a boulder from the far side
      v_cover := CASE WHEN v_against = 'EE' THEN public.rpg_cover(p_actor_id, v_tid) END;
      IF v_cover = 'full' THEN
        RAISE EXCEPTION '% is behind a boulder: no blow reaches them from here', v_t.name;
      END IF;
      v_roll := public.rpg_roll(v_actor.character_id, v_key, v_diff, v_label, NULL, v_s.id, p_actor_id,
                                CASE WHEN jsonb_array_length(v_plan) = 1 THEN p_roll END, v_target_card);
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
      -- (step 14f-battle) half cover: a blow that lands on someone behind a fallen log strikes the log when its die is in
      -- the lower half of the dice that land, so half the blows get through, as half the body is open to them
      IF v_cover IN ('half', 'wind') AND v_first->>'result' <> '' AND (v_first->>'roll')::integer - v_needs < (100 - v_needs) / 2.0 THEN
        v_blocked := true; v_net := 0;
        v_tail := CASE WHEN v_cover = 'wind'
                       -- (weather step 2b) the wind blew it off its mark (rpg_cover 'wind')
                       THEN ' The wind carried it wide of ' || v_t.name || ' (rolled ' || (v_first->>'roll') || ': in this wind a blow from 2 squares away or more needs '
                            || ceil(v_needs + (100 - v_needs) / 2.0)::integer || ').'
                       ELSE ' Struck the fallen log in front of ' || v_t.name || ' (rolled ' || (v_first->>'roll') || ': past half cover a blow needs '
                            || ceil(v_needs + (100 - v_needs) / 2.0)::integer || ').' END;
      END IF;
      -- Gate 2: block. Someone holding a shield or weapon; the Shield of Faith against a spiritual effect.
      IF v_first->>'result' <> '' AND NOT v_blocked AND v_t.character_id IS NOT NULL AND (v_damage_ok OR v_spirit_fx) THEN
        v_blk := NULL; v_blocker := NULL; v_blocker_name := NULL;
        IF v_damage_ok THEN
          -- the best unbroken thing held: its object's Integrity (Toughness ÷ 5) adds to Block
          SELECT i.id, i.name, (s->>'ig')::numeric INTO v_blocker, v_blocker_name, v_blk FROM public.rpg_items i CROSS JOIN LATERAL public.rpg_object_state(i.object_id) s
           WHERE i.character_id = v_t.character_id AND i.equipped AND NOT i.worn AND NOT (s->>'broken')::boolean
           ORDER BY (s->>'ig')::numeric DESC, i.sort_order LIMIT 1;
          IF v_blocker IS NOT NULL THEN v_blk := coalesce(public.rpg_participant_value(v_tid, 'BLK'), 0) + coalesce(v_blk, 0) + v_know_def; END IF;
        ELSE
          -- the Shield of Faith blocks while it has life left (3 × its value); broken, it blocks nothing until Prayer or Bible Study restore it
          v_shield := public.rpg_armor_state(v_t.character_id, (SELECT d.key FROM public.rpg_stat_definitions d WHERE d.guards = 'block' LIMIT 1));
          IF v_shield IS NULL OR (v_shield->>'broken')::boolean THEN v_blk := NULL; ELSE v_blk := public.rpg_participant_value(v_tid, v_shield->>'key') + v_know_def; END IF;
          v_blocker_name := coalesce(v_shield->>'name', 'Shield of Faith');
        END IF;
        IF v_blk IS NOT NULL THEN
          v_broll := public.rpg_roll(v_actor.character_id, v_key, public.rpg_difficulty(v_blk, public.rpg_participant_can_act(v_tid), v_defending), v_label || ' (block)', NULL, v_s.id, p_actor_id, NULL, v_target_card);
          IF v_broll->>'result' = '' THEN
            v_blocked := true; v_net := 0;
            v_tail := ' Blocked by ' || CASE WHEN v_blocker IS NOT NULL THEN v_t.name || '''s ' || v_blocker_name ELSE v_t.name || '''s Shield of Faith' END
                      || ' (rolled ' || (v_broll->>'roll') || ', needs ' || ceil((v_broll->>'needed')::numeric) || ').';
            IF v_blocker IS NOT NULL AND v_dmg > 0 THEN
              v_wear := public.rpg_item_damage(v_blocker, v_dmg);
              v_tail := v_tail || ' The ' || v_blocker_name || ' takes ' || v_dmg || CASE WHEN (v_wear->>'broke')::boolean THEN ' and breaks.' ELSE ', ' || (v_wear->>'left') || ' left.' END;
              IF v_weapon IS NOT NULL THEN PERFORM public.rpg_item_damage(v_weapon, ceil(v_dmg / 5.0)::integer); END IF;
            END IF;
            IF v_blocker IS NULL AND v_spirit_fx THEN
              -- the Shield of Faith takes the attack's strength: the landing die minus what it needed
              v_wear := public.rpg_armor_wear(v_t.character_id, v_shield->>'key', greatest((v_first->>'roll')::integer - v_needs, 0));
              v_tail := v_tail || ' The ' || (v_shield->>'name') || ' takes ' || (v_wear->>'taken')::numeric::integer || CASE WHEN (v_wear->>'broke')::boolean THEN ' and breaks.' ELSE ', ' || (v_wear->>'left')::numeric::integer || ' left.' END;
            END IF;
          ELSE
            v_tail := ' Past the block (rolled ' || (v_broll->>'roll') || ', needs ' || ceil((v_broll->>'needed')::numeric) || ').';
          END IF;
        END IF;
      END IF;
      -- Gate 3: hit. Armor absorbs and takes what it absorbed; the weapon a fifth.
      IF v_dmg > 0 AND NOT v_blocked AND v_t.character_id IS NOT NULL THEN
        -- worn and unbroken: each absorbs its object's Integrity (Toughness ÷ 5) and takes that much itself
        FOR v_item IN SELECT i.id, i.name, (s->>'ig')::integer AS absorb FROM public.rpg_items i CROSS JOIN LATERAL public.rpg_object_state(i.object_id) s
                       WHERE i.character_id = v_t.character_id AND i.equipped AND i.worn AND (s->>'ig')::integer > 0 AND NOT (s->>'broken')::boolean ORDER BY (s->>'ig')::integer DESC LOOP
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
      -- An attack on the heart or the mind (the card's "aim"): the armor piece that guards it absorbs up to its own value
      -- of the attack's strength (the die minus what it needed) and wears by that much; only what is left puts the
      -- effect on. Zaboo's Breastplate 10 against a Briar Roar of strength 23: takes 10, 13 gets through, Frightened;
      -- strength 8: turned aside. Broken, or with no value, it absorbs nothing.
      v_turned := false;
      IF v_kind = 'action' AND v_fx->>'aim' IS NOT NULL AND v_fx->>'on' = 'land' AND v_first->>'result' <> '' AND NOT v_blocked AND v_t.character_id IS NOT NULL THEN
        v_piece := public.rpg_armor_state(v_t.character_id, (SELECT d.key FROM public.rpg_stat_definitions d WHERE d.guards = v_fx->>'aim' LIMIT 1));
        IF v_piece IS NOT NULL AND (v_piece->>'value')::numeric > 0 AND NOT (v_piece->>'broken')::boolean THEN
          v_strength := greatest((v_first->>'roll')::integer - v_needs, 0);
          v_absorb := least(floor((v_piece->>'value')::numeric)::integer, v_strength);
          v_wear := public.rpg_armor_wear(v_t.character_id, v_piece->>'key', v_absorb);
          IF v_strength - v_absorb <= 0 THEN
            v_turned := true;
            v_tail := v_tail || ' ' || v_t.name || '''s ' || (v_piece->>'name') || ' turns it aside'
                      || CASE WHEN v_absorb > 0 THEN ' (takes ' || v_absorb || CASE WHEN (v_wear->>'broke')::boolean THEN ' and breaks)' ELSE ', ' || (v_wear->>'left')::numeric::integer || ' of ' || (v_wear->>'life')::numeric::integer || ' left)' END ELSE '' END || '.';
          ELSE
            v_tail := v_tail || ' ' || v_t.name || '''s ' || (v_piece->>'name') || ' takes ' || v_absorb
                      || CASE WHEN (v_wear->>'broke')::boolean THEN ' and breaks' ELSE ', ' || (v_wear->>'left')::numeric::integer || ' of ' || (v_wear->>'life')::numeric::integer || ' left' END
                      || '; ' || (v_strength - v_absorb) || ' gets through.';
          END IF;
        END IF;
      END IF;
      v_out := CASE WHEN v_blocked THEN jsonb_build_object('key', 'blocked', 'label', 'Blocked')
                    WHEN v_turned THEN jsonb_build_object('key', 'bounced', 'label', 'Turned aside')
                    WHEN v_bounced THEN jsonb_build_object('key', 'bounced', 'label', 'Bounced off')
                    ELSE public.rpg_outcome((v_first->>'roll')::integer, (v_first->>'needed')::numeric, (v_first->>'critical')::numeric, v_damage_ok, v_net,
                                            (public.rpg_needed(coalesce(v_first->>'skill', '0')::numeric, v_diff_still)->>'needed')::numeric) END;
      v_levelup := CASE WHEN (v_roll->>'level_after')::integer > (v_first->>'level_before')::integer
                        THEN ' ' || v_actor.name || '''s ' || coalesce(v_first->>'stat_name', v_label) || ' goes up to ' || (v_roll->>'level_after') || '!' ELSE '' END;
      -- knowledge in the log: "(Knowing Bramblemaw 3; Bramblemaw 2 knows Human 2)"
      v_know_txt := concat_ws('; ',
        CASE WHEN coalesce((v_first->'knowledge'->>'value')::numeric, 0) > 0 THEN (v_first->'knowledge'->>'name') || ' ' || trim_scale((v_first->'knowledge'->>'value')::numeric) END,
                       CASE WHEN coalesce((v_first->'place_knowledge'->>'value')::numeric, 0) > 0 THEN (v_first->'place_knowledge'->>'name') || ' ' || trim_scale((v_first->'place_knowledge'->>'value')::numeric) END,
        CASE WHEN v_know_def > 0 THEN v_t.name || ' knows ' || (SELECT k.name FROM public.rpg_creatures k WHERE k.id = v_actor_card) || ' ' || trim_scale(v_know_def) END);
      v_know_txt := CASE WHEN v_know_txt <> '' THEN ' (' || v_know_txt || ')' ELSE '' END;
      -- Built with IF, not CASE: PL/pgSQL plans every CASE branch, and v_use is only assigned for a card action.
      IF v_kind = 'attack' THEN
        v_who := v_actor.name || ' attacks ' || v_t.name || ' with ' || v_label
                 || CASE WHEN coalesce((v_first->>'bulk_over')::integer, 0) > 0 THEN ' (bulk ' || (v_first->>'bulk_over') || ' over: rolls as ' || trim_scale((v_first->>'skill')::numeric) || ')' ELSE '' END || v_know_txt;
      ELSIF v_kind = 'action' THEN
        v_who := v_actor.name || '''s ' || v_use.name || CASE WHEN v_use.id <> v_act.id THEN ' (' || v_act.name || ')' ELSE '' END
                 || ' at ' || v_t.name || CASE WHEN v_damage_ok THEN '' ELSE ' (' || v_against_name || ')' END || v_know_txt;
      ELSE
        v_who := v_actor.name || ' rolls ' || v_label || ' against ' || v_t.name || '''s ' || v_against_name || v_know_txt;
      END IF;
      -- Players see a creature's health as a bar only, so the log gives a number left only for characters.
      v_tail := v_tail || CASE WHEN v_net > 0 AND (v_vit->>'left')::integer <= 0 THEN ' ' || v_t.name || ' ' || coalesce(v_vit->>'fell', 'is down') || '.'
                               WHEN v_net > 0 AND v_t.creature_id IS NULL THEN ' ' || v_t.name || ' has ' || (v_vit->>'left') || ' left.'
                               ELSE '' END;
      -- A hostile roll marks the actor as having attacked (no longer an innocent) and, if they are Judged and the target
      -- is an innocent, condemns them (rpg_judgement). A Miss counts: the attempt is the harm.
      IF NOT v_ending AND (v_kind = 'attack' OR (v_kind = 'action' AND (v_damage_ok OR v_fx ? 'apply'))) THEN
        v_tail := v_tail || coalesce(public.rpg_judgement(p_actor_id, v_tid, false), '');
        UPDATE public.rpg_session_participants SET has_attacked = true WHERE id = p_actor_id AND NOT has_attacked;
      END IF;
      IF v_ending AND v_first->>'result' <> '' THEN
        v_rev := NULL;
        SELECT e INTO v_rev FROM jsonb_array_elements(v_t.effects) e WHERE e ? 'ended_by' LIMIT 1;
        UPDATE public.rpg_session_participants p
           SET effects = (SELECT coalesce(jsonb_agg(z), '[]'::jsonb) FROM jsonb_array_elements(p.effects) z WHERE NOT z ? 'ended_by')
                         || jsonb_build_array(jsonb_build_object('name', v_rev->'ended_by'->>'name', 'cannot_act', true, 'source', v_label))
         WHERE p.id = v_tid;
        v_tail := v_tail || ' ' || v_t.name || ' is ' || (v_rev->'ended_by'->>'name') || ' and will not rise.';
      END IF;
      IF v_kind = 'action' AND v_fx IS NOT NULL AND v_first->>'result' <> '' AND NOT v_blocked AND NOT v_bounced AND NOT v_turned AND (v_vit->>'left')::integer > 0 THEN
        IF v_fx->>'on' = 'land' AND NOT v_damage_ok THEN
          PERFORM public.rpg_participant_apply_effect(v_tid, (v_fx->'apply') || jsonb_build_object('source_id', p_actor_id), v_use.name, v_s.round);
          v_tail := v_tail || ' ' || v_t.name || ' is ' || (v_fx->'apply'->>'name') || '.';
        ELSIF v_fx->>'on' = 'hit' AND v_net > 0 AND v_fx ? 'contest' THEN
          v_cdiff := public.rpg_difficulty(coalesce(public.rpg_participant_value(v_tid, v_fx->'contest'->>'against'), 0) + v_know_def, public.rpg_participant_can_act(v_tid), v_defending);
          v_croll := public.rpg_roll(v_actor.character_id, v_fx->'contest'->>'skill_key', v_cdiff, v_use.name || ' (' || (v_fx->'apply'->>'name') || ')', NULL, v_s.id, p_actor_id, NULL, v_target_card);
          IF v_croll->>'result' <> '' THEN
            PERFORM public.rpg_participant_apply_effect(v_tid, (v_fx->'apply') || jsonb_build_object('source_id', p_actor_id), v_use.name, v_s.round);
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

  IF v_beats > 0 AND (v_kind IN ('attack', 'action') OR v_ending OR v_discipline) THEN
    UPDATE public.rpg_sessions SET turn_action_ticks = public.rpg_action_ticks(p_actor_id, v_beats, CASE WHEN v_kind = 'attack' THEN p_stat_key END) WHERE id = v_s.id;
  END IF;
  IF v_ecost > 0 AND (v_kind IN ('attack', 'action') OR v_ending OR v_discipline) THEN
    IF v_etype = 'spiritual' THEN UPDATE public.rpg_session_participants SET energy_used_spiritual = energy_used_spiritual + v_ecost WHERE id = p_actor_id;
    ELSE UPDATE public.rpg_session_participants SET energy_used_physical = energy_used_physical + v_ecost WHERE id = p_actor_id; END IF;
  END IF;
  IF v_kind = 'action' THEN
    UPDATE public.rpg_session_participants
       SET legendary_left = legendary_left - CASE WHEN v_act.kind = 'legendary' THEN v_act.legendary_cost ELSE 0 END,
           lair_round = CASE WHEN v_act.kind = 'lair' THEN v_s.round ELSE lair_round END
     WHERE id = p_actor_id;
  END IF;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_s.id;
  RETURN jsonb_build_object('kind', v_kind, 'label', v_label, 'results', v_results);
END;
$function$
;
UPDATE public.rpg_rules SET body = replace(replace(body, $o1$Clear or cloudy weather lets you see the full 2.7 miles.\n*A 20-mile walk in fog$o1$, $n1$Clear or cloudy weather lets you see the full 2.7 miles.
*A 20-mile walk in fog$n1$), $o2$so a 20-mile walk of 6 h 40 min takes about 8 h 34 min.*$o2$, $n2$so a 20-mile walk of 6 h 40 min takes about 8 h 34 min.*
In a fight outdoors the weather counts too (not under the ground or inside a building). Every step takes the weather's extra time on top of the ground's, as on a walk. Rain, a thunderstorm, snow or a blizzard soak what would burn, so a square set alight does not catch. A dust storm keeps a fire burning a round longer, 4 rounds instead of 3. A thunderstorm, a blizzard or a dust storm blows shots off their mark: a blow from 2 squares away or more that lands is carried wide when its die is in the lower half of the dice that land, the same as half cover.
*In a blizzard a plain square at +5% takes 5 × 2.05 = 10.25 ticks at Speed 10 instead of 5.25, so a turn's 20 ticks of moving cover 1 such square instead of 3. A longbow needing 50 in a thunderstorm lands on 50 to 100, but 50 to 74 are carried wide; only 75 or more go on to the Block gate.*$n2$), updated_at = now() WHERE key = 'world_map' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';
-- (one quote mark to balance the text above for the SQL tool) '

