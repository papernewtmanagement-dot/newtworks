-- roleplaying_map4_knowing_places: world map step 4 (Peter 2026-10-03 03:54, "Defaults" = 1A knowing a place works
-- like knowing a creature, 2A found = within sight, 2.7 miles each way, of where a piece walked). The kids login sees
-- the Maps tab: only what the group has found or knows, and it walks its own characters on their turns.

ALTER TABLE public.rpg_characters ADD COLUMN IF NOT EXISTS map_trail jsonb NOT NULL DEFAULT '[]'::jsonb;
COMMENT ON COLUMN public.rpg_characters.map_trail IS 'Every stretch this character walked on the world map, [x0, y0, x1, y1] in world squares from 1; what it has seen is worked out from these (rpg_map_found), nothing per square.';

INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'sight_squares', 3885, 'How far a piece sees each way on the world map: 2.7 miles, the horizon for eye height (3.57 x square root of 1.5 m = 4.4 km)')
ON CONFLICT (agency_id, key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.rpg_seg_box(p_x0 double precision, p_y0 double precision, p_x1 double precision, p_y1 double precision,
                                             p_bx0 double precision, p_by0 double precision, p_bx1 double precision, p_by1 double precision)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
-- Whether a stretch from x0, y0 to x1, y1 passes through a box (bx0..bx1 across, by0..by1 down): the part of the
-- stretch inside the box, found one axis at a time, is not empty. A stretch of one point is a point.
SELECT greatest(0, tx.lo, ty.lo) <= least(1, tx.hi, ty.hi)
  FROM (SELECT CASE WHEN p_x1 = p_x0 THEN CASE WHEN p_x0 BETWEEN p_bx0 AND p_bx1 THEN 0 ELSE 2 END
                    ELSE least((p_bx0 - p_x0) / (p_x1 - p_x0), (p_bx1 - p_x0) / (p_x1 - p_x0)) END AS lo,
               CASE WHEN p_x1 = p_x0 THEN CASE WHEN p_x0 BETWEEN p_bx0 AND p_bx1 THEN 1 ELSE -1 END
                    ELSE greatest((p_bx0 - p_x0) / (p_x1 - p_x0), (p_bx1 - p_x0) / (p_x1 - p_x0)) END AS hi) tx,
       (SELECT CASE WHEN p_y1 = p_y0 THEN CASE WHEN p_y0 BETWEEN p_by0 AND p_by1 THEN 0 ELSE 2 END
                    ELSE least((p_by0 - p_y0) / (p_y1 - p_y0), (p_by1 - p_y0) / (p_y1 - p_y0)) END AS lo,
               CASE WHEN p_y1 = p_y0 THEN CASE WHEN p_y0 BETWEEN p_by0 AND p_by1 THEN 1 ELSE -1 END
                    ELSE greatest((p_by0 - p_y0) / (p_y1 - p_y0), (p_by1 - p_y0) / (p_y1 - p_y0)) END AS hi) ty;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_trails()
 RETURNS TABLE(x0 bigint, y0 bigint, x1 bigint, y1 bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Every stretch the group has walked: the map trails of the player characters (not non-player characters, not
-- creatures made for a fight). The kids login shares one map, so what any of them saw, all of them see.
SELECT (e->>0)::bigint, (e->>1)::bigint, (e->>2)::bigint, (e->>3)::bigint
  FROM public.rpg_characters c CROSS JOIN LATERAL jsonb_array_elements(c.map_trail) e
 WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND NOT c.is_npc AND c.session_id IS NULL;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_trail_add(p_character_id uuid, p_x0 integer, p_y0 integer, p_x1 integer, p_y1 integer)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Adds one walked stretch (or, placed by hand, one square: both ends the same) to a player character map trail.
UPDATE public.rpg_characters SET map_trail = map_trail || jsonb_build_array(jsonb_build_array(p_x0, p_y0, p_x1, p_y1))
 WHERE id = p_character_id AND NOT is_npc AND session_id IS NULL;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_found(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The cells of a block of one grid the group has found (Peter 2026-10-03, 2A): any part of the cell lies within
-- sight_squares (3,885 squares, 2.7 miles) of a stretch some player character walked (rpg_map_trails), counted the
-- way the game counts distance, the larger of the two gaps. A cell of a coarse grid is found once any of it is seen.
WITH lad AS (SELECT l.cell::bigint AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     sg AS (SELECT s.value::bigint AS sight FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'sight_squares'),
     seg AS MATERIALIZED (
       SELECT t.x0, t.y0, t.x1, t.y1 FROM public.rpg_map_trails() t CROSS JOIN lad CROSS JOIN sg
        WHERE greatest(t.x0, t.x1) >= p_x0 * lad.cell + 1 - sg.sight AND least(t.x0, t.x1) <= (p_x0 + p_cols) * lad.cell + sg.sight
          AND greatest(t.y0, t.y1) >= p_y0 * lad.cell + 1 - sg.sight AND least(t.y0, t.y1) <= (p_y0 + p_rows) * lad.cell + sg.sight)
SELECT gx, gy
  FROM lad CROSS JOIN sg CROSS JOIN generate_series(p_x0, p_x0 + p_cols - 1) AS gx CROSS JOIN generate_series(p_y0, p_y0 + p_rows - 1) AS gy
 WHERE EXISTS (SELECT 1 FROM seg WHERE public.rpg_seg_box(seg.x0, seg.y0, seg.x1, seg.y1,
                                                          gx * lad.cell + 1 - sg.sight, gy * lad.cell + 1 - sg.sight,
                                                          (gx + 1) * lad.cell + sg.sight, (gy + 1) * lad.cell + sg.sight));
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_place_seen(p_card uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Whether the group has seen any of a place: a walked stretch comes within sight of the box round its oval.
SELECT EXISTS (SELECT 1 FROM public.rpg_creatures p CROSS JOIN public.rpg_map_trails() t
                CROSS JOIN (SELECT s.value::bigint AS sight FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'sight_squares') sg
                WHERE p.id = p_card AND p.place_w IS NOT NULL
                  AND public.rpg_seg_box(t.x0, t.y0, t.x1, t.y1, p.place_x - p.place_w / 2.0 + 1 - sg.sight, p.place_y - p.place_h / 2.0 + 1 - sg.sight,
                                         p.place_x + p.place_w / 2.0 + 1 + sg.sight, p.place_y + p.place_h / 2.0 + 1 + sg.sight));
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_known_places()
 RETURNS uuid[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The place cards the group knows well enough to see whole on the map (Peter 2026-10-03, 1A): some player character
-- has its Knowing <place> open and at 1 or more, read the way rpg_knows reads it (the sheet values and the skill tree),
-- each sheet read once.
DECLARE v_c record; v_v jsonb; v_t jsonb; v_out uuid[] := '{}';
BEGIN
  FOR v_c IN SELECT c.id, c.template_id FROM public.rpg_characters c
              WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND NOT c.is_npc AND c.session_id IS NULL LOOP
    v_v := public.rpg_sheet_values(v_c.id) -> 'values';
    v_t := public.rpg_skill_tree(v_c.template_id, v_v);
    v_out := v_out || coalesce((SELECT array_agg(d.knows_id)
                                  FROM public.rpg_stat_definitions d JOIN public.rpg_creatures p ON p.id = d.knows_id AND p.place_w IS NOT NULL
                                 WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365'
                                   AND coalesce((v_t -> d.key ->> 'open')::boolean, false) AND coalesce((v_v ->> d.key)::numeric, 0) >= 1
                                   AND NOT d.knows_id = ANY (v_out)), '{}'::uuid[]);
  END LOOP;
  RETURN v_out;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_place_at(p_x integer, p_y integer)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The place a world square (from 1) lies in: the smallest place card whose oval covers it, a land that only names
-- the ground (Havenmark) when no smaller place does. In the Thornfields that is the Thornfields.
SELECT p.id FROM public.rpg_creatures p CROSS JOIN (SELECT l.span AS w FROM public.rpg_map_ladder() l WHERE l.level = 1) w
 WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND p.is_active AND p.place_w IS NOT NULL
   AND public.rpg_map_covers(p_x - 0.5::double precision, p_y - 0.5::double precision, p.place_x, p.place_y, p.place_w, p.place_h, w.w)
 ORDER BY p.place_w::bigint * p.place_h, p.id LIMIT 1;
$function$;

-- Changed in place, by exact replacements on the live definitions of 2026-10-03:

CREATE OR REPLACE FUNCTION public.rpg_roll(p_character_id uuid, p_stat_key text, p_difficulty numeric DEFAULT NULL::numeric, p_label text DEFAULT NULL::text, p_parent_roll_id uuid DEFAULT NULL::uuid, p_session_id uuid DEFAULT NULL::uuid, p_participant_id uuid DEFAULT NULL::uuid, p_roll integer DEFAULT NULL::integer, p_card uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One d100 roll of one stat from a sheet. Everyone who rolls has a sheet: a player character, or a creature made
-- from its card for a fight. Rolling a trainable stat earns skill points on every roll: die × Needed ÷ 100 (Peter
-- 2026-09-24), so a 70 when Needed is 50 earns 35. p_roll is a die rolled by hand (1 to 100) used in place of the
-- random one. Needed comes from rpg_needed; an opponent's difficulty arrives already derived by rpg_difficulty.
-- After the roll's own points, rpg_trickle sends half as much down to what the skill is built from; 'grew' lists
-- every stat that climbed a level from that (Karen's Footwork reaching 1, her Sword reading 7).
-- p_card is what the roll is at or about (a target's card, or a card being studied): the roller's knowledge of it
-- (rpg_knows: Knowing Bramblemaw 3) adds to the skill for this roll, and the trickle feeds that knowledge as one more
-- weight-1 part. Rolling a knowledge skill about its own card is plain study: nothing added, nothing doubled.
-- The place the roller stands in counts the same way (Peter 2026-10-03, 1A): on a journey, the smallest place card
-- round the square of the roller (rpg_map_place_at); Knowing Thornfields 2 makes Sword 8 roll as 10 there, and the
-- trickle feeds Knowing Thornfields as one more weight-1 part.
DECLARE
  v_sheet jsonb; v_stat jsonb; v_skill numeric; v_diff numeric; v_nc jsonb; v_roll integer; v_result text;
  v_points numeric := 0; v_before integer; v_after integer; v_grew jsonb := '{}'::jsonb; v_discipline boolean := false; v_burden integer := 0; v_disc jsonb := NULL; v_id uuid; v_agency uuid; v_name text; v_trainable boolean := false; v_over integer := 0; v_know numeric := 0; v_know_key text; v_know_name text;
  v_place uuid; v_pk_key text; v_pk_name text; v_pknow numeric := 0;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  v_diff := coalesce(p_difficulty, public.rpg_setting('default_difficulty'));
  IF v_diff < 0 THEN RAISE EXCEPTION 'difficulty cannot be negative'; END IF;
  IF p_roll IS NOT NULL AND (p_roll < 1 OR p_roll > 100) THEN RAISE EXCEPTION 'a roll is 1 to 100'; END IF;
  IF p_character_id IS NULL THEN RAISE EXCEPTION 'every roll needs a sheet'; END IF;
  IF NOT public.rpg_can_see_character(p_character_id) THEN RAISE EXCEPTION 'character not found'; END IF;

  v_sheet := public.rpg_sheet(p_character_id, v_diff);
  SELECT s INTO v_stat FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = p_stat_key;
  IF v_stat IS NULL THEN
    -- the sheet leaves a shut skill out (rpg_skill_tree), so rolling one is refused by name: Sword with Grip at 0
    SELECT d.name INTO v_name FROM public.rpg_characters c
     CROSS JOIN LATERAL public.rpg_template_stat_defs(c.template_id) d
     WHERE c.id = p_character_id AND d.key = p_stat_key
       AND (public.rpg_skill_tree(c.template_id, public.rpg_sheet_values(c.id) -> 'values') -> d.key ->> 'open') = 'false';
    IF v_name IS NOT NULL THEN
      RAISE EXCEPTION '% is not open yet: every skill it is built on must be open and at a third of its own bar', v_name;
    END IF;
    RAISE EXCEPTION 'unknown stat %', p_stat_key;
  END IF;
  v_skill := (v_stat->>'value')::numeric;
  v_name := v_stat->>'name';
  v_trainable := coalesce((v_stat->>'trainable')::boolean, false);
  -- a bulky weapon in hand: each point of its bulk past the roller's handling takes 1 off the skill for this swing (the
  -- sheet carries it as the stat's 'bulk', from rpg_weapon_bulk); the level climbed from is still the sheet's
  v_over := coalesce((v_stat->'bulk'->>'over')::integer, 0);
  v_skill := greatest(v_skill - v_over, 0);
  -- knowledge of what the roll is at (rpg_knows): the roller's Knowing <card> adds to the skill for this roll; the level climbed from is still the sheet's
  IF p_card IS NOT NULL THEN
    SELECT d.key, d.name INTO v_know_key, v_know_name FROM public.rpg_characters c CROSS JOIN LATERAL public.rpg_template_stat_defs(c.template_id) d
     WHERE c.id = p_character_id AND d.knows_id = p_card;
    IF v_know_key = p_stat_key THEN v_know_key := NULL; v_know_name := NULL; END IF;
    IF v_know_key IS NOT NULL THEN v_know := public.rpg_knows(p_character_id, p_card); v_skill := v_skill + v_know; END IF;
  END IF;
  -- knowledge of the place the roller stands in, on a journey (rpg_map_place_at), the same way
  IF p_participant_id IS NOT NULL THEN
    SELECT public.rpg_map_place_at(p.pos_x, p.pos_y) INTO v_place
      FROM public.rpg_session_participants p JOIN public.rpg_sessions s ON s.id = p.session_id
     WHERE p.id = p_participant_id AND s.on_map AND p.pos_x IS NOT NULL;
    IF v_place IS NOT NULL AND v_place IS DISTINCT FROM p_card THEN
      SELECT d.key, d.name INTO v_pk_key, v_pk_name FROM public.rpg_characters c CROSS JOIN LATERAL public.rpg_template_stat_defs(c.template_id) d
       WHERE c.id = p_character_id AND d.knows_id = v_place;
      IF v_pk_key = p_stat_key THEN v_pk_key := NULL; v_pk_name := NULL; END IF;
      IF v_pk_key IS NOT NULL THEN v_pknow := public.rpg_knows(p_character_id, v_place); v_skill := v_skill + v_pknow; END IF;
    END IF;
  END IF;
  -- Prayer and Bible Study: the burden of sins and bad decisions raises their difficulty by its amount (burden 6: 5 becomes 11)
  SELECT coalesce(d.spirit_discipline, false) INTO v_discipline FROM public.rpg_stat_definitions d WHERE d.key = p_stat_key;
  IF v_discipline THEN
    SELECT coalesce(spiritual_burden, 0) INTO v_burden FROM public.rpg_characters WHERE id = p_character_id;
    v_diff := v_diff + v_burden;
  END IF;
  SELECT agency_id INTO v_agency FROM public.rpg_characters WHERE id = p_character_id;

  v_nc := public.rpg_needed(v_skill, v_diff);
  v_roll := coalesce(p_roll, floor(random() * 100)::integer + 1);
  v_result := CASE WHEN v_roll >= (v_nc->>'critical')::numeric THEN 'C'
                   WHEN v_roll >= (v_nc->>'needed')::numeric THEN 'Y' ELSE '' END;
  v_before := (v_stat->>'value')::numeric::integer; v_after := v_before;

  IF v_trainable THEN
    v_points := v_roll * (v_nc->>'needed')::numeric / 100;
    v_after := public.rpg_add_skill_points(p_character_id, p_stat_key, v_points, v_before);
    v_grew := public.rpg_trickle(p_character_id, p_stat_key, v_points, (CASE WHEN v_know_key IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(jsonb_build_array(v_know_key, 1)) END)
                                                                     || (CASE WHEN v_pk_key IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(jsonb_build_array(v_pk_key, 1)) END));
  END IF;
  -- a successful Prayer or Bible Study eases the burden and restores the armor of God, most-worn piece first (rpg_discipline_effects)
  IF v_discipline AND v_result <> '' THEN
    v_disc := public.rpg_discipline_effects(p_character_id, v_roll - (v_nc->>'needed')::numeric);
  END IF;

  INSERT INTO public.rpg_rolls (agency_id, character_id, participant_id, session_id, stat_key, skill, difficulty, needed,
                                critical_at, roll, result, points_awarded, level_before, level_after, parent_roll_id,
                                extra_pending, label, manual, card_id)
  VALUES (v_agency, p_character_id, p_participant_id, p_session_id, p_stat_key, v_skill, v_diff,
          (v_nc->>'needed')::numeric, (v_nc->>'critical')::numeric, v_roll, v_result, v_points, v_before, v_after,
          p_parent_roll_id, v_result = 'C', p_label, p_roll IS NOT NULL, p_card)
  RETURNING id INTO v_id;
  IF p_parent_roll_id IS NOT NULL THEN
    UPDATE public.rpg_rolls SET extra_pending = false WHERE id = p_parent_roll_id;
  END IF;

  RETURN jsonb_build_object('roll_id', v_id, 'character_id', p_character_id, 'participant_id', p_participant_id,
    'stat_key', p_stat_key, 'stat_name', v_name, 'skill', v_skill, 'difficulty', v_diff, 'needed', v_nc->'needed',
    'critical', v_nc->'critical', 'roll', v_roll, 'result', v_result, 'points', round(v_points, 1),
    'level_before', v_before, 'level_after', v_after, 'grew', v_grew, 'discipline', v_disc, 'bulk_over', v_over, 'card_id', p_card, 'knowledge', CASE WHEN v_know_key IS NULL THEN NULL ELSE jsonb_build_object('key', v_know_key, 'name', v_know_name, 'value', v_know) END,
    'place_knowledge', CASE WHEN v_pk_key IS NULL THEN NULL ELSE jsonb_build_object('key', v_pk_key, 'name', v_pk_name, 'value', v_pknow) END, 'extra_pending', v_result = 'C', 'manual', p_roll IS NOT NULL,
    'parent_roll_id', p_parent_roll_id, 'label', p_label, 'created_at', now());
END;
$function$;

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
      -- Gate 2: block. Someone holding a shield or weapon; the Shield of Faith against a spiritual effect.
      IF v_first->>'result' <> '' AND v_t.character_id IS NOT NULL AND (v_damage_ok OR v_spirit_fx) THEN
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
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_turn(p_participant_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The checks every move on the world map makes first, in one place: someone allowed to play (the kids login moves
-- characters, only the game master moves creatures), the piece is on a
-- journey (a session played on the world map), the journey has started and is not over, and it is the turn of this
-- piece. Locks the journey and returns its id.
DECLARE v_p record; v_s record;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not on this journey'; END IF;
  IF v_p.creature_id IS NOT NULL AND NOT public.family_is_parent() THEN RAISE EXCEPTION 'the game master moves %', v_p.name; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id FOR UPDATE;
  IF NOT v_s.on_map THEN RAISE EXCEPTION 'that is a fight, not a journey'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that journey is over'; END IF;
  IF v_s.status <> 'active' THEN RAISE EXCEPTION 'start the journey first'; END IF;
  IF v_s.current_participant_id IS DISTINCT FROM p_participant_id THEN RAISE EXCEPTION 'it is not the turn of %', v_p.name; END IF;
  RETURN v_s.id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_add(p_session_id uuid, p_character_id uuid DEFAULT NULL::uuid, p_creature_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Adds one character, or one creature made fresh from its card, to a fight at its Agility place: ahead of the first
-- one in line with lower Agility, so higher Agility acts first and a tie goes after whoever joined first; that order breaks ties on the fight
-- clock. Joining a fight already on, the first turn comes one beat from now (Speed 7: 12 ticks). A creature is made the way any character is made (rpg_new_character from its card, as a
-- non-player character), kept for this fight only (session_id) and left off the lists of players. So two Ashwing
-- Harriers are two different rolls (Physical Vitality 40 to 50), while a boss card like the Bramblemaw comes out the
-- same every time. The Bramblemaw (Agility 7) lands ahead of Karen (Agility 1). A second one is named "Bramblemaw 2".
DECLARE v_s record; v_name text; v_card uuid; v_leg integer := 0; v_n integer; v_id uuid; v_char uuid := p_character_id; v_ag numeric; v_pos integer;
BEGIN
  PERFORM public.require_login('family');
  -- the game master adds by hand; the site itself adds a creature met on a journey (rpg_map_walk, rpg.engine on)
  IF NOT public.family_is_parent() AND coalesce(current_setting('rpg.engine', true), '') <> 'on' THEN RAISE EXCEPTION 'only the game master adds to a fight'; END IF;
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
    SELECT name, id, legendary_per_round INTO v_name, v_card, v_leg FROM public.rpg_creatures WHERE id = p_creature_id AND is_active;
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
  IF v_s.status = 'active' THEN
    UPDATE public.rpg_session_participants SET next_tick = v_s.clock + public.rpg_action_ticks(v_id, 1) WHERE id = v_id;
  END IF;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, actor_id, text)
  VALUES (v_s.agency_id, p_session_id, v_s.round, 'join', v_id, v_name || CASE WHEN v_s.on_map THEN ' joins the journey (Agility ' ELSE ' joins the fight (Agility ' END || trim_scale(v_ag) || ').');
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = p_session_id;
  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_walk(p_participant_id uuid, p_x integer, p_y integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A piece walks toward a world square (p_x, p_y counted from 1, as pieces stand; the map works from 0 inside) on
-- its turn, the whole way in one go: the same movement rule as a fight, at every level (Peter 2026-10-01). Every
-- square entered costs 1 plus its movement penalty (rpg_map_ground), move_ticks (5) a point at Speed 10, faster or
-- slower by Speed (rpg_ticks_at: base x 20 / (10 + Speed)). A tick is 1/6 of a second (Peter 2026-10-03, 1B), so open
-- land goes at about 3 miles an hour at Speed 10: 20 miles in 6 h 40 min.
-- The walk runs straight (rpg_map_line, ground from rpg_map_route, looked at closer where the sea starts) and stops:
--   at the shore: nobody walks into the sea (2A); the piece stands on the last dry square before it;
--   when the walking day runs out: a piece walks at most walk_day_hours (8) between camps (day_walk_ticks counts it),
--   then camps camp_hours (16) where it stands. The square it was heading for is kept (walk_to_x, walk_to_y) so the
--   next turn can carry on;
--   one square short of a square another piece stands on;
--   when a creature is met: every full hour walked inside a haunt (rpg_map_haunters; haunt_ticks carries the part
--   hour on) the site rolls a d100, and at encounter_chance (15) or less a creature of that haunt is met where the
--   hour ran out (Peter 2026-10-03, 1A). It joins the journey encounter_squares (10) away (rpg_map_set_down) and the
--   fight is on, on that ground. A piece in a fight (rpg_map_in_fight) moves on the fight board, not across the map;
--   creatures always do.
-- The end square is checked on the battle grid itself (dry, nobody on it), stepping back along the walk if it must.
-- The time walked plus any camp is the turn (turn_move_ticks), and the turn passes on (rpg_session_next_turn).
-- Pieces stand on world squares counted from 1 (pos_x = square + 1), like squares on a fight board.
DECLARE
  v_sid uuid; v_p record; v_r record; v_world integer; v_down integer;
  v_tph integer; v_day integer; v_camp integer; v_mt integer; v_even numeric; v_speed numeric; v_ign boolean;
  v_left integer; v_basemax bigint; v_steps integer; v_kmax integer; v_reach integer := 0;
  v_pen integer; v_b integer; v_n integer; v_base bigint := 0; v_why text;
  v_rf integer[] := '{}'; v_rt integer[] := '{}'; v_rb integer[] := '{}';
  v_k integer := 0; v_lo integer; v_hi integer; i integer;
  v_from integer; v_cut integer; v_pass integer; v_lvl integer; v_sea_from integer; v_sea_to integer;
  v_sx integer; v_sy integer; v_tx integer; v_ty integer;
  v_walk integer := 0; v_camped boolean; v_arrived boolean; v_text text; v_next jsonb;
  v_gx integer; v_gy integer; v_hx integer; v_hy integer; v_cards uuid[]; v_t0 integer; v_t1 integer; v_h0 integer; v_haunt integer;
  v_hour integer; v_d100 integer; v_rolls integer[] := '{}'; v_need bigint; v_meet uuid; v_chance integer; v_cp uuid; v_gap integer;
BEGIN
  v_sid := public.rpg_map_turn(p_participant_id);
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF v_p.pos_x IS NULL THEN RAISE EXCEPTION '% is not on the map yet', v_p.name; END IF;
  IF v_p.creature_id IS NOT NULL THEN RAISE EXCEPTION 'creatures move on the fight board'; END IF;
  IF public.rpg_map_in_fight(p_participant_id) THEN RAISE EXCEPTION '% is in a fight: move on the fight board', v_p.name; END IF;
  SELECT l.span, l.span / 2 INTO v_world, v_down FROM public.rpg_map_ladder() l WHERE l.level = 1;
  IF p_x IS NULL OR p_y IS NULL OR p_x NOT BETWEEN 1 AND v_world OR p_y NOT BETWEEN 1 AND v_down THEN
    RAISE EXCEPTION 'that square is off the map';
  END IF;
  v_sx := v_p.pos_x - 1; v_sy := v_p.pos_y - 1; v_gx := p_x - 1; v_gy := p_y - 1;
  v_haunt := v_p.haunt_ticks; v_chance := public.rpg_setting('encounter_chance')::integer;
  v_tph := public.rpg_setting('ticks_per_hour')::integer;
  v_day := public.rpg_setting('walk_day_hours')::integer * v_tph;
  v_camp := public.rpg_setting('camp_hours')::integer * v_tph;
  v_mt := public.rpg_setting('move_ticks')::integer;
  v_even := public.rpg_setting('speed_even');
  v_speed := public.rpg_participant_speed(p_participant_id);
  v_ign := public.rpg_participant_ignores_penalty(p_participant_id);
  SELECT l.steps INTO v_steps FROM public.rpg_map_line(v_sx, v_sy, v_gx, v_gy) l;
  IF v_steps = 0 THEN RAISE EXCEPTION '% is already there', v_p.name; END IF;

  -- the most base time what is left of the walking day holds, and so the most steps it could hold on open land
  v_left := greatest(v_day - v_p.day_walk_ticks, 0);
  v_basemax := greatest(ceil((v_left + 0.5) * (v_even + v_speed) / (2 * v_even))::bigint - 1, 0);
  WHILE v_basemax > 0 AND public.rpg_ticks_at(v_speed, v_basemax) > v_left LOOP v_basemax := v_basemax - 1; END LOOP;
  v_kmax := least(v_steps::bigint, v_basemax / v_mt)::integer;

  -- read at the usual grid first; where that grid sees sea, look again closer (a finer grid over just that stretch)
  -- until the battle grid says where the shore is; a stretch that is dry after all is walked and the walk goes on
  v_from := 1; v_cut := v_kmax;
  FOR v_pass IN 1 .. 40 LOOP
    v_why := NULL; v_lvl := 7;
    FOR v_r IN SELECT * FROM public.rpg_map_route(v_sx, v_sy, v_gx, v_gy, v_cut, v_from) LOOP
      v_lvl := v_r.level;
      SELECT g.penalty INTO v_pen FROM public.rpg_map_ground(v_r.kind, v_r.place_id) g;
      IF v_pen IS NULL THEN v_why := 'shore'; v_sea_from := v_r.k_from; v_sea_to := v_r.k_to; EXIT; END IF;
      v_b := v_mt * (1 + CASE WHEN v_ign THEN 0 ELSE v_pen END);
      v_n := least(v_r.k_to - v_r.k_from + 1, ((v_basemax - v_base) / v_b)::integer);
      -- every full hour walked inside a haunt is one roll (Peter 2026-10-03, 1A)
      IF v_n > 0 THEN
        SELECT s.x + 1, s.y + 1 INTO v_hx, v_hy FROM public.rpg_map_line_at(v_sx, v_sy, v_gx, v_gy, v_r.k_from) s;
        v_cards := public.rpg_map_haunters(v_hx, v_hy);
        IF v_cards IS NOT NULL THEN
          v_t0 := public.rpg_ticks_at(v_speed, v_base);
          v_t1 := public.rpg_ticks_at(v_speed, v_base + v_n::bigint * v_b);
          v_h0 := v_haunt;
          v_haunt := v_haunt + (v_t1 - v_t0);
          FOR v_hour IN (v_h0 / v_tph) + 1 .. (v_haunt / v_tph) LOOP
            v_d100 := floor(random() * 100)::integer + 1;
            v_rolls := v_rolls || v_d100;
            IF v_d100 <= v_chance THEN
              -- met where that hour ran out: the first step whose time reaches it
              v_need := v_hour::bigint * v_tph - v_h0;
              v_n := least(greatest(ceil(v_need * (v_even + v_speed) / (2 * v_even) / v_b)::integer, 1), v_n);
              v_haunt := v_h0 + public.rpg_ticks_at(v_speed, v_base + v_n::bigint * v_b) - v_t0;
              v_meet := v_cards[1 + floor(random() * cardinality(v_cards))::integer];
              v_why := 'meet';
              EXIT;
            END IF;
          END LOOP;
        END IF;
      END IF;
      v_rf := v_rf || v_r.k_from; v_rt := v_rt || (v_r.k_from + v_n - 1); v_rb := v_rb || v_b;
      v_base := v_base + v_n::bigint * v_b;
      v_reach := v_r.k_from + v_n - 1;
      EXIT WHEN v_why = 'meet';
      IF v_n < v_r.k_to - v_r.k_from + 1 THEN v_why := 'day'; EXIT; END IF;
    END LOOP;
    IF v_why = 'shore' AND v_lvl < 7 THEN
      v_from := v_sea_from; v_cut := v_sea_to;
    ELSIF v_why IS NULL AND v_cut < v_kmax THEN
      v_from := v_cut + 1; v_cut := v_kmax;
    ELSE
      EXIT;
    END IF;
  END LOOP;
  IF v_why IS NULL AND v_reach < v_steps THEN v_why := 'day'; END IF;

  -- the end square, on the battle grid: the furthest step that is dry and free, in blocks of 12 steps back
  v_hi := v_reach;
  WHILE v_hi >= 1 AND v_hi > v_reach - 144 AND v_k = 0 LOOP
    v_lo := greatest(v_hi - 11, 1);
    WITH sq AS MATERIALIZED (
           SELECT g.k, s.x, s.y FROM generate_series(v_lo, v_hi) AS g(k)
            CROSS JOIN LATERAL public.rpg_map_line_at(v_sx, v_sy, v_gx, v_gy, g.k) s),
         ux AS MATERIALIZED (
           -- a block that crosses the east-west edge of the world is kept in one piece
           SELECT sq.k, sq.x, sq.y,
                  sq.x + CASE WHEN max(sq.x) OVER () - min(sq.x) OVER () > 12 AND sq.x < v_world / 2 THEN v_world ELSE 0 END AS ux
             FROM sq),
         bb AS (SELECT min(ux.ux) AS x0, max(ux.ux) AS x1, min(ux.y) AS y0, max(ux.y) AS y1 FROM ux)
    SELECT max(ux.k) INTO v_k
      FROM ux CROSS JOIN bb
      JOIN LATERAL public.rpg_map_cells(7, bb.x0, bb.y0, bb.x1 - bb.x0 + 1, bb.y1 - bb.y0 + 1) c ON c.x = ux.ux AND c.y = ux.y
     WHERE c.kind <> 'sea'
       AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants o
                        WHERE o.session_id = v_sid AND o.id <> p_participant_id AND o.pos_x = ux.x + 1 AND o.pos_y = ux.y + 1
                          AND public.rpg_participant_blocks(o.id));
    v_k := coalesce(v_k, 0);
    v_hi := v_lo - 1;
  END LOOP;

  v_base := 0;
  FOR i IN 1 .. coalesce(array_length(v_rf, 1), 0) LOOP
    v_base := v_base + greatest(least(v_rt[i], v_k) - v_rf[i] + 1, 0)::bigint * v_rb[i];
  END LOOP;
  v_walk := public.rpg_ticks_at(v_speed, v_base);
  v_arrived := v_k = v_steps;
  v_camped := coalesce(v_why, '') = 'day' OR v_p.day_walk_ticks + v_walk >= v_day;
  IF v_k = 0 AND NOT v_camped THEN
    RAISE EXCEPTION '%', CASE WHEN v_why = 'shore' THEN 'the sea is in the way' ELSE 'someone is in the way' END;
  END IF;

  v_tx := v_sx; v_ty := v_sy;
  IF v_k > 0 THEN SELECT s.x, s.y INTO v_tx, v_ty FROM public.rpg_map_line_at(v_sx, v_sy, v_gx, v_gy, v_k) s; END IF;
  UPDATE public.rpg_session_participants
     SET pos_x = v_tx + 1, pos_y = v_ty + 1,
         day_walk_ticks = CASE WHEN v_camped THEN 0 ELSE day_walk_ticks + v_walk END,
         walk_to_x = CASE WHEN NOT v_arrived AND (v_camped AND coalesce(v_why, '') = 'day' OR v_why = 'meet') THEN p_x END,
         walk_to_y = CASE WHEN NOT v_arrived AND (v_camped AND coalesce(v_why, '') = 'day' OR v_why = 'meet') THEN p_y END,
         haunt_ticks = v_haunt
   WHERE id = p_participant_id;
  -- what the character saw on the way (rpg_map_found reads these stretches)
  IF v_k > 0 THEN PERFORM public.rpg_map_trail_add(v_p.character_id, v_sx + 1, v_sy + 1, v_tx + 1, v_ty + 1); END IF;
  UPDATE public.rpg_sessions
     SET turn_move_ticks = v_walk + CASE WHEN v_camped THEN v_camp ELSE 0 END, turn_action_ticks = 0, updated_at = now()
   WHERE id = v_sid;
  v_text := v_p.name
         || CASE WHEN v_k > 0 THEN ' walks ' || public.rpg_map_length_text(v_k) || ' in ' || public.rpg_map_duration_text(v_walk) || '.'
                 ELSE ' has walked all day.' END
         || CASE WHEN v_why = 'shore' THEN ' The sea stops the walk.' ELSE '' END
         || CASE WHEN v_camped THEN ' Camps for ' || public.rpg_map_duration_text(v_camp) || '.' ELSE '' END
         || CASE WHEN v_camped AND NOT v_arrived AND coalesce(v_why, '') = 'day'
                 THEN ' Still ' || public.rpg_map_length_text(v_steps - v_k) || ' to go.' ELSE '' END;
  IF v_why = 'meet' THEN
    PERFORM set_config('rpg.engine', 'on', true);
    v_cp := public.rpg_session_add(v_sid, NULL, v_meet);
    PERFORM public.rpg_map_set_down(v_cp, v_tx + 1, v_ty + 1, public.rpg_setting('encounter_squares')::integer);
    -- both see each other when the walk stops: each first acts one beat after that moment, as when a fight starts
    UPDATE public.rpg_session_participants
       SET next_tick = (SELECT s.clock FROM public.rpg_sessions s WHERE s.id = v_sid) + v_walk + public.rpg_action_ticks(v_cp, 1)
     WHERE id = v_cp;
    UPDATE public.rpg_sessions SET turn_move_ticks = v_walk + public.rpg_action_ticks(p_participant_id, 1) WHERE id = v_sid;
    SELECT public.rpg_square_gap(v_tx + 1, v_ty + 1, c.pos_x, c.pos_y) INTO v_gap FROM public.rpg_session_participants c WHERE c.id = v_cp;
    v_text := v_text || ' An hour in a haunt: the site rolls ' || v_rolls[cardinality(v_rolls)] || ', ' || v_chance || ' or less meets a creature. '
           || (SELECT c.name FROM public.rpg_session_participants c WHERE c.id = v_cp)
           || CASE WHEN v_gap IS NULL THEN ' is here!' ELSE ' appears ' || public.rpg_map_length_text(v_gap) || ' away!' END;
  ELSIF cardinality(v_rolls) > 0 THEN
    v_text := v_text || ' Hours in a haunt: the site rolls ' || array_to_string(v_rolls, ', ') || ' (' || v_chance || ' or less meets a creature).';
  END IF;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  SELECT s.agency_id, s.id, s.round, 'move', 'info', p_participant_id, v_text FROM public.rpg_sessions s WHERE s.id = v_sid;
  v_next := public.rpg_session_next_turn(v_sid);
  RETURN jsonb_build_object('text', v_text, 'arrived', v_arrived, 'stopped', v_why, 'camped', v_camped, 'next', v_next);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_place(p_participant_id uuid, p_x integer DEFAULT NULL::integer, p_y integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The game master puts a piece on a square of the world map (counted from 1, as pieces stand), or with no square takes
-- it off. Free, any time, but never onto the sea or a square someone takes up; placing a piece forgets where it was
-- heading. A fight off the map has no board, so there it can only take someone off.
DECLARE v_p record; v_s record; v_who text;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master places fighters'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id FOR UPDATE;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  IF p_x IS NULL OR p_y IS NULL THEN
    UPDATE public.rpg_session_participants SET pos_x = NULL, pos_y = NULL, walk_to_x = NULL, walk_to_y = NULL WHERE id = p_participant_id;
  ELSE
    IF NOT v_s.on_map THEN RAISE EXCEPTION 'this fight is off the map, so it has no board; meet creatures on a journey'; END IF;
    IF p_x NOT BETWEEN 1 AND (SELECT l.span FROM public.rpg_map_ladder() l WHERE l.level = 1)
       OR p_y NOT BETWEEN 1 AND (SELECT l.span / 2 FROM public.rpg_map_ladder() l WHERE l.level = 1) THEN
      RAISE EXCEPTION 'that square is off the map';
    END IF;
    IF (SELECT f.sea FROM public.rpg_fight_square(v_s.id, p_x, p_y) f) THEN RAISE EXCEPTION 'that square is sea'; END IF;
    SELECT o.name INTO v_who FROM public.rpg_session_participants o
     WHERE o.session_id = v_p.session_id AND o.id <> v_p.id AND o.pos_x = p_x AND o.pos_y = p_y AND public.rpg_participant_blocks(o.id) LIMIT 1;
    IF v_who IS NOT NULL THEN RAISE EXCEPTION '% is on that square', v_who; END IF;
    UPDATE public.rpg_session_participants SET pos_x = p_x, pos_y = p_y, walk_to_x = NULL, walk_to_y = NULL WHERE id = p_participant_id;
    IF v_p.creature_id IS NULL THEN PERFORM public.rpg_map_trail_add(v_p.character_id, p_x, p_y, p_x, p_y); END IF;
  END IF;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_s.id;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_view(p_level integer DEFAULT 1, p_x integer DEFAULT 0, p_y integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The Maps tab in one read, game master only: one grid of the world map, drawn from the place cards and the map
-- rolls (rpg_map_cells). p_level 1 is the world; a deeper grid is named by its level and by the cell of the grid
-- above that it fills, counted across the whole world: 3, 88, 41 is the Country grid inside cell 88, 41 of the
-- Continent grids.
-- Returns the grid (level, name, title, cols, rows, scale), the way back up (crumbs), the grid next door each way
-- (moves), every cell in reading order (x, y, its name like C5, kind sea / land / forest / hills / mountains /
-- place, place = the card it belongs to, marks = other place cards reaching into it, open = the grid inside it),
-- every place card (name, color, icon = the name of its map symbol, size, ground = its ground in words or nothing
-- when it only names the land, the place it is inside, level = the kind of place it is, view = the grid of its own
-- level around its center, listed = it belongs on this grid's list, spot = where to write its name on this grid:
-- its center from the top-left corner, then its width and height, all four in thousandths of a cell, or nothing
-- when the center is off the grid), list = what this grid lists, the places one level down that reach into it
-- (the world lists continents, a continent countries, a country regions, a region cities, a city districts, a
-- district battle grids; a battle grid lists nothing), within = the continent, country and so on that hold the
-- middle of this grid, biggest first (only places that name the land, the smallest of each kind), grounds = each
-- kind of unnamed ground with its name and, when it has one, its movement penalty in words, and the ladder of
-- grids in words.
-- The world also carries detail: every cell of the Continent grids inside it, 144 across and 72 down, one
-- character a cell (~ sea, . open land, t forest, h hills, m mountains, else the character numbered 256 + the
-- place's spot in detail.places, counted from 0), so the world is drawn as fine as the grids inside it.
-- Each cell also carries to = the world square at its middle (counted from 1, as pieces stand), where a piece walks or is placed when
-- the cell is tapped. journey = the open journey, if any (a session played on the world map): its clock in words,
-- whose turn it is, its last lines of log, every piece (where it stands on this grid in thousandths of a cell like a
-- place spot, the cell name, the grid of this zoom that holds it, when its next turn comes, what is left of its walking day, the
-- square it is heading for and how far that is; for a creature met in its haunt whether it is out of the fight; and
-- whether the piece is in a fight, rpg_map_in_fight) and the characters that can still join.
-- The kids login sees the same read, cut to what the group has found (Peter 2026-10-03, 2A: within sight of where a
-- piece walked, rpg_map_found) or knows (1A: Knowing a place at 1 or more shows all of it, rpg_map_known_places):
-- other cells come as kind unknown with no place, places and lands only once found or known, a place lore only once
-- known, creatures only within sight of a character, and nothing to add.
-- The page draws these as given and works nothing out itself.
DECLARE
  v_l         record;
  v_last      integer;
  v_world     integer;
  v_x         integer := coalesce(p_x, 0);
  v_y         integer := coalesce(p_y, 0);
  v_x0        integer := 0;
  v_y0        integer := 0;
  v_gx0       bigint;
  v_gy0       bigint;
  v_gx1       bigint;
  v_gy1       bigint;
  v_up_cell   integer;
  v_up_across integer;
  v_up_down   integer;
  v_dc        integer;
  v_dr        integer;
  v_cells     jsonb;
  v_detail    jsonb;
  v_crumbs    jsonb;
  v_places    jsonb;
  v_list      jsonb;
  v_within    jsonb;
  v_grounds   jsonb;
  v_ladder    jsonb;
  v_moves     jsonb;
  v_scale     text;
  v_journey   jsonb;
  v_gm        boolean;
  v_known     uuid[] := '{}';
  v_seen      jsonb := '{}';
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  v_gm := public.family_is_parent();
  SELECT * INTO v_l FROM public.rpg_map_ladder() l WHERE l.level = coalesce(p_level, 1);
  IF NOT FOUND THEN RAISE EXCEPTION 'that grid is off the map'; END IF;
  SELECT max(l.level) INTO v_last FROM public.rpg_map_ladder() l;
  SELECT l.span INTO v_world FROM public.rpg_map_ladder() l WHERE l.level = 1;
  IF v_l.level = 1 THEN
    IF v_x <> 0 OR v_y <> 0 THEN RAISE EXCEPTION 'that grid is off the map'; END IF;
  ELSE
    SELECT l.cell, l.across, l.down INTO v_up_cell, v_up_across, v_up_down FROM public.rpg_map_ladder() l WHERE l.level = v_l.level - 1;
    IF v_x NOT BETWEEN 0 AND v_up_across - 1 OR v_y NOT BETWEEN 0 AND v_up_down - 1 THEN RAISE EXCEPTION 'that grid is off the map'; END IF;
    v_x0 := v_x * v_l.cols;
    v_y0 := v_y * v_l.rows;
    v_moves := jsonb_build_object(
      'west',  v_l.level::text || '-' || mod(v_x - 1 + v_up_across, v_up_across)::text || '-' || v_y::text,
      'east',  v_l.level::text || '-' || mod(v_x + 1, v_up_across)::text || '-' || v_y::text,
      'north', CASE WHEN v_y > 0 THEN v_l.level::text || '-' || v_x::text || '-' || (v_y - 1)::text END,
      'south', CASE WHEN v_y < v_up_down - 1 THEN v_l.level::text || '-' || v_x::text || '-' || (v_y + 1)::text END);
  END IF;
  -- the corners of this grid in world squares
  v_gx0 := v_x0::bigint * v_l.cell;
  v_gy0 := v_y0::bigint * v_l.cell;
  v_gx1 := (v_x0 + v_l.cols)::bigint * v_l.cell;
  v_gy1 := (v_y0 + v_l.rows)::bigint * v_l.cell;

  IF NOT v_gm THEN
    v_known := public.rpg_map_known_places();
    SELECT coalesce(jsonb_object_agg(f.x || ',' || f.y, true), '{}'::jsonb) INTO v_seen
      FROM public.rpg_map_found(v_l.level, v_x0, v_y0, v_l.cols, v_l.rows) f;
  END IF;

  SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'x', c.x - v_x0 + 1, 'y', c.y - v_y0 + 1,
           'name', public.rpg_square_name(c.x - v_x0 + 1, c.y - v_y0 + 1),
           'kind', CASE WHEN k.seen THEN c.kind ELSE 'unknown' END, 'place', CASE WHEN k.seen THEN c.place_id END,
           'marks', CASE WHEN k.seen AND cardinality(c.marks) > 0 THEN to_jsonb(c.marks) END,
           'open', CASE WHEN v_l.level < v_last THEN (v_l.level + 1)::text || '-' || c.x::text || '-' || c.y::text END,
           'to', jsonb_build_array(c.x::bigint * v_l.cell + v_l.cell / 2 + 1, c.y::bigint * v_l.cell + v_l.cell / 2 + 1)))
         ORDER BY c.y, c.x)
    INTO v_cells
    FROM public.rpg_map_cells(v_l.level, v_x0, v_y0, v_l.cols, v_l.rows) c
   CROSS JOIN LATERAL (SELECT v_gm OR v_seen ? (c.x || ',' || c.y)
                              OR EXISTS (SELECT 1 FROM public.rpg_creatures p
                                          WHERE p.id = ANY (v_known)
                                            AND public.rpg_map_covers(((c.x + 0.5) * v_l.cell)::double precision, ((c.y + 0.5) * v_l.cell)::double precision,
                                                                      p.place_x, p.place_y, p.place_w, p.place_h, v_world)) AS seen) k;

  IF v_l.level = 1 THEN
    SELECT l.across, l.down INTO v_dc, v_dr FROM public.rpg_map_ladder() l WHERE l.level = 2;
    IF NOT v_gm THEN
      SELECT coalesce(jsonb_object_agg(f.x || ',' || f.y, true), '{}'::jsonb) INTO v_seen FROM public.rpg_map_found(2, 0, 0, v_dc, v_dr) f;
    END IF;
    WITH d AS MATERIALIZED (
           SELECT c.x, c.y, c.kind, c.place_id,
                  v_gm OR v_seen ? (c.x || ',' || c.y)
                  OR EXISTS (SELECT 1 FROM public.rpg_creatures p, public.rpg_map_ladder() q
                              WHERE q.level = 2 AND p.id = ANY (v_known)
                                AND public.rpg_map_covers(((c.x + 0.5) * q.cell)::double precision, ((c.y + 0.5) * q.cell)::double precision,
                                                          p.place_x, p.place_y, p.place_w, p.place_h, v_world)) AS seen
             FROM public.rpg_map_cells(2, 0, 0, v_dc, v_dr) c),
         u AS (SELECT coalesce(array_agg(q.id ORDER BY q.sort_order, q.name), '{}'::uuid[]) AS ids
                 FROM (SELECT DISTINCT c.id, c.sort_order, c.name
                         FROM d JOIN public.rpg_creatures c ON c.id = d.place_id WHERE d.seen) q),
         ln AS (SELECT d.y, string_agg(CASE WHEN NOT d.seen THEN '?' ELSE CASE d.kind WHEN 'sea' THEN '~' WHEN 'land' THEN '.' WHEN 'forest' THEN 't'
                                                   WHEN 'hills' THEN 'h' WHEN 'mountains' THEN 'm'
                                                   ELSE chr(255 + array_position(u.ids, d.place_id)) END END, '' ORDER BY d.x) AS line
                  FROM d CROSS JOIN u
                 GROUP BY d.y)
    SELECT jsonb_build_object('cols', v_dc, 'rows', v_dr, 'places', to_jsonb((SELECT u.ids FROM u)),
                              'cells', jsonb_agg(ln.line ORDER BY ln.y))
      INTO v_detail
      FROM ln;
  END IF;

  SELECT jsonb_agg(CASE WHEN l.level = 1 THEN jsonb_build_object('label', l.name, 'view', NULL)
                        ELSE jsonb_build_object(
                          'label', l.name || ' ' || public.rpg_square_name(mod(v_x / (u.cell / v_up_cell), u.cols) + 1, mod(v_y / (u.cell / v_up_cell), u.rows) + 1),
                          'view', l.level::text || '-' || (v_x / (u.cell / v_up_cell))::text || '-' || (v_y / (u.cell / v_up_cell))::text) END
                   ORDER BY l.level)
    INTO v_crumbs
    FROM public.rpg_map_ladder() l LEFT JOIN public.rpg_map_ladder() u ON u.level = l.level - 1
   WHERE l.level <= v_l.level;

  v_scale := public.rpg_map_length_text(v_l.span)
          || CASE WHEN v_l.level = 1 THEN ' around. Each cell is '
                  WHEN v_l.level = v_last THEN ' across. Each square is '
                  ELSE ' across. Each cell is ' END
          || public.rpg_map_length_text(v_l.cell) || '.';

  SELECT jsonb_agg(jsonb_build_object(
           'id', c.id, 'name', c.name, 'color', c.color, 'icon', c.place_icon,
           'ground', CASE WHEN c.place_penalty IS NOT NULL THEN public.rpg_map_ground_text(c.place_forest, c.place_penalty) END,
           'size', CASE WHEN c.place_w = c.place_h THEN public.rpg_map_length_text(c.place_w) || ' across'
                        ELSE public.rpg_map_length_text(c.place_w) || ' by ' || public.rpg_map_length_text(c.place_h) END,
           'about', CASE WHEN v_gm OR c.id = ANY (v_known) THEN c.lore END,
           'inside', (SELECT p.name FROM public.rpg_creatures p WHERE p.id = c.parent_id AND p.place_w IS NOT NULL),
           'level', f.name,
           'view', f.level::text || '-' || (c.place_x / f.span)::text || '-' || (c.place_y / f.span)::text,
           'listed', c.place_level = v_l.level + 1
                     AND public.rpg_map_touches(v_gx0::double precision, v_gy0::double precision, v_gx1::double precision, v_gy1::double precision,
                                                c.place_x, c.place_y, c.place_w, c.place_h, v_world),
           'spot', CASE WHEN s.cx - v_gx0 >= 0 AND s.cx - v_gx0 < v_gx1 - v_gx0 AND c.place_y - v_gy0 >= 0 AND c.place_y - v_gy0 < v_gy1 - v_gy0
                        THEN jsonb_build_array(((s.cx - v_gx0) * 1000 + v_l.cell / 2) / v_l.cell,
                                               ((c.place_y - v_gy0) * 1000 + v_l.cell / 2) / v_l.cell,
                                               (c.place_w::bigint * 1000 + v_l.cell / 2) / v_l.cell,
                                               (c.place_h::bigint * 1000 + v_l.cell / 2) / v_l.cell) END)
         ORDER BY c.sort_order, c.name)
    INTO v_places
    FROM public.rpg_creatures c
    JOIN public.rpg_map_ladder() f ON f.level = c.place_level
   -- its center, as the copy nearest the middle of this grid (the map wraps east to west)
   CROSS JOIN LATERAL (SELECT c.place_x + v_world::bigint * floor(((v_gx0 + v_gx1) / 2.0::double precision - c.place_x) / v_world + 0.5)::bigint AS cx) s
   WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL
     AND (v_gm OR c.id = ANY (v_known) OR public.rpg_map_place_seen(c.id));

  SELECT coalesce(jsonb_agg(q.name ORDER BY q.place_level), '[]'::jsonb)
    INTO v_within
    FROM (SELECT DISTINCT ON (c.place_level) c.place_level, c.name
            FROM public.rpg_creatures c
           WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL
             AND c.place_penalty IS NULL AND c.place_level <= v_l.level
             AND (v_gm OR c.id = ANY (v_known) OR public.rpg_map_place_seen(c.id))
             AND public.rpg_map_covers((v_gx0 + v_gx1) / 2.0::double precision, (v_gy0 + v_gy1) / 2.0::double precision,
                                       c.place_x, c.place_y, c.place_w, c.place_h, v_world)
           ORDER BY c.place_level, c.place_w::bigint * c.place_h, c.id) q;

  SELECT jsonb_build_object('title', q.title, 'empty', 'No ' || lower(q.title) || ' named here yet.')
    INTO v_list
    FROM (SELECT CASE WHEN l.name LIKE '%y' THEN left(l.name, -1) || 'ies' ELSE l.name || 's' END AS title
            FROM public.rpg_map_ladder() l WHERE l.level = v_l.level + 1) q;

  SELECT jsonb_strip_nulls(jsonb_build_object(
           'sea', jsonb_build_object('name', 'Sea'),
           'land', jsonb_build_object('name', 'Open land'),
           'forest', jsonb_build_object('name', 'Forest', 'penalty', CASE WHEN g.forest > 0 THEN public.rpg_map_ground_text(false, g.forest) END),
           'hills', jsonb_build_object('name', 'Hills', 'penalty', CASE WHEN g.hills > 0 THEN public.rpg_map_ground_text(false, g.hills) END),
           'mountains', jsonb_build_object('name', 'Mountains', 'penalty', CASE WHEN g.mountains > 0 THEN public.rpg_map_ground_text(false, g.mountains) END)))
    INTO v_grounds
    FROM (SELECT (SELECT r.penalty FROM public.rpg_map_ground('forest') r) AS forest,
                 (SELECT r.penalty FROM public.rpg_map_ground('hills') r) AS hills,
                 (SELECT r.penalty FROM public.rpg_map_ground('mountains') r) AS mountains) g;

  SELECT jsonb_agg(jsonb_build_object('name', l.name, 'line',
           public.rpg_map_length_text(l.span)
           || CASE WHEN l.level = 1 THEN ' around, cells of '
                   WHEN l.level = v_last THEN ' across, squares of '
                   ELSE ' across, cells of ' END
           || public.rpg_map_length_text(l.cell)) ORDER BY l.level)
    INTO v_ladder
    FROM public.rpg_map_ladder() l;

  SELECT jsonb_build_object(
           'id', s.id, 'name', s.name, 'status', s.status, 'time', public.rpg_map_time_text(s.clock),
           'current', s.current_participant_id,
           'log', coalesce((SELECT jsonb_agg(e.text ORDER BY e.created_at DESC)
                              FROM (SELECT e.text, e.created_at FROM public.rpg_events e
                                     WHERE e.session_id = s.id ORDER BY e.created_at DESC LIMIT 6) e), '[]'::jsonb),
           'pieces', coalesce((
             SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                      'id', p.id, 'name', p.name, 'color', coalesce(cr.color, ch.color), 'placed', p.pos_x IS NOT NULL,
                      'creature', p.creature_id IS NOT NULL,
                      'out', CASE WHEN p.creature_id IS NOT NULL AND public.rpg_participant_out(p.id) THEN 'out of the fight' END,
                      'fight', public.rpg_map_in_fight(p.id),
                      'spot', CASE WHEN q.sx >= v_gx0 AND q.sx < v_gx1 AND q.sy >= v_gy0 AND q.sy < v_gy1
                                   THEN jsonb_build_array(((q.sx - v_gx0) * 1000 + 500) / v_l.cell, ((q.sy - v_gy0) * 1000 + 500) / v_l.cell) END,
                      'cell', CASE WHEN q.sx >= v_gx0 AND q.sx < v_gx1 AND q.sy >= v_gy0 AND q.sy < v_gy1
                                   THEN public.rpg_square_name(((q.sx - v_gx0) / v_l.cell + 1)::integer, ((q.sy - v_gy0) / v_l.cell + 1)::integer) END,
                      'find', CASE WHEN p.pos_x IS NOT NULL AND v_l.level > 1 THEN v_l.level::text || '-' || (q.sx / v_l.span)::text || '-' || (q.sy / v_l.span)::text END,
                      'next', CASE WHEN s.status = 'active' AND p.id IS DISTINCT FROM s.current_participant_id AND p.next_tick IS NOT NULL
                                   THEN public.rpg_map_duration_text(greatest(p.next_tick - s.clock, 0)) END,
                      'day_left', public.rpg_map_duration_text(greatest(d.day - p.day_walk_ticks, 0)),
                      'walk_to', CASE WHEN p.walk_to_x IS NOT NULL THEN jsonb_build_array(p.walk_to_x, p.walk_to_y) END,
                      'to_go', CASE WHEN p.walk_to_x IS NOT NULL AND p.pos_x IS NOT NULL
                                    THEN public.rpg_map_length_text((SELECT w.steps FROM public.rpg_map_line(q.sx::integer, q.sy::integer, p.walk_to_x - 1, p.walk_to_y - 1) w)) END))
                    ORDER BY p.next_tick NULLS LAST, p.turn_order, p.created_at)
               FROM public.rpg_session_participants p
               LEFT JOIN public.rpg_characters ch ON ch.id = p.character_id
               LEFT JOIN public.rpg_creatures cr ON cr.id = p.creature_id
              CROSS JOIN LATERAL (SELECT p.pos_x::bigint - 1 AS sx, p.pos_y::bigint - 1 AS sy) q
              CROSS JOIN (SELECT public.rpg_setting('walk_day_hours')::integer * public.rpg_setting('ticks_per_hour')::integer AS day) d
              WHERE p.session_id = s.id
                AND (v_gm OR p.creature_id IS NULL
                     OR EXISTS (SELECT 1 FROM public.rpg_session_participants o
                                 WHERE o.session_id = s.id AND o.creature_id IS NULL AND o.pos_x IS NOT NULL AND p.pos_x IS NOT NULL
                                   AND public.rpg_square_gap(o.pos_x, o.pos_y, p.pos_x, p.pos_y) <= public.rpg_setting('sight_squares')))), '[]'::jsonb),
           'can_join', CASE WHEN NOT v_gm THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) ORDER BY c.name)
                                   FROM public.rpg_characters c
                                  WHERE c.is_active AND NOT c.is_npc AND c.session_id IS NULL
                                    AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants o
                                                     WHERE o.session_id = s.id AND o.character_id = c.id)), '[]'::jsonb) END)
    INTO v_journey
    FROM public.rpg_sessions s
   WHERE s.on_map AND s.status <> 'ended'
   ORDER BY s.created_at DESC LIMIT 1;

  RETURN jsonb_build_object(
    'level', v_l.level, 'name', v_l.name, 'title', v_crumbs -> -1 ->> 'label',
    'view', CASE WHEN v_l.level > 1 THEN v_l.level::text || '-' || v_x::text || '-' || v_y::text END,
    'cols', v_l.cols, 'rows', v_l.rows, 'scale', v_scale,
    'crumbs', v_crumbs, 'moves', v_moves,
    'cells', coalesce(v_cells, '[]'::jsonb), 'detail', v_detail,
    'places', coalesce(v_places, '[]'::jsonb), 'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'journey', v_journey,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $function$;

-- The rule cards (the admin manual page follows by its trigger):
UPDATE public.rpg_rules SET body = replace(body, 'A player''s sheet lists a knowledge skill once that card is shown to players, or once the character has met or studied it.', 'A player''s sheet lists a knowledge skill once that card is shown to players, or once the character has met or studied it.

Places count the same way. On a journey, every roll you make adds your knowledge of the place you stand in (the smallest place round your square), and every roll there feeds that knowledge. Knowing a place at 1 or more also shows all of it on your map.
*Karen in the Thornfields with Knowing Thornfields 2 swings Sword 8 as 10. Against Evade Enemy 8 (difficulty 16) she needs 100 × 16 ÷ 26 = 62 instead of 67.*'), updated_at = now() WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'knowledge' AND position('A player''s sheet lists a knowledge skill once that card is shown to players, or once the character has met or studied it.' in body) > 0;
UPDATE public.rpg_rules SET body = replace(body, 'a piece moves on the fight board, a turn at a time, instead of walking the map.', 'a piece moves on the fight board, a turn at a time, instead of walking the map.

The map shows what your group has found: everything within 2.7 miles each way of where any of you walked, the distance to the horizon for a person''s eyes. The rest stays blank until someone goes there or knows the place.
*A 20-mile walk shows a strip about 25 miles long and 5.4 miles wide.*'), updated_at = now() WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map' AND position('a piece moves on the fight board, a turn at a time, instead of walking the map.' in body) > 0;

