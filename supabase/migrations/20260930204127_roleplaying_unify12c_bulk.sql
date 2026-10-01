-- roleplaying_unify12c_bulk
-- Peter 2026-09-30, "Defaults" (1A 2A 3A): bulk. Weight is muscle (Strength carries it); bulk is technique: how hard
-- a thing is to move quickly because of its length and balance, a set number on the weapon's card (BK, like WT).
-- Handling = the levels of the basics the weapon's skill is built on (its formula's plus list: Swing arm + Grip +
-- Footwork for a sword) + (Strength + Agility) ÷ 10, whole part. Each point of bulk past the handling takes 1 off the
-- weapon skill for that swing (rpg_roll, and the sheet's "needs") and figures the swing's ticks at 1 less Speed
-- (rpg_action_ticks). rpg_weapon_bulk is the one home of the weapon in hand, its bulk, the handling and the excess.

-- 1. The Bulk stat on the Object card, set on every weapon card; nothing to swing stays 0. Two new cards swung with
--    the Sword skill: Long sword and Bastard sword.
INSERT INTO public.rpg_stat_definitions (agency_id, key, name, abbr, kind, grp, trainable, sort_order, template_id, default_value, beats, energy_cost, energy_type, reach, is_attack, spirit_discipline)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'BK', 'Bulk', 'BK', 'fixed', 'physical', false, 136, '0e55221a-403b-490e-9509-062e2113d723', 0, 2, 4, 'physical', 1, false, false)
ON CONFLICT DO NOTHING;

INSERT INTO public.rpg_creatures (key, name, parent_id, blueprint, shown_to_players, sort_order, worn, weapon_key, color)
VALUES ('long_sword', 'Long sword', '0e55221a-403b-490e-9509-062e2113d723', '{"TO": {"divisor": 5}, "WT": 4, "BK": 3}'::jsonb, false, 1002, false, 'sword', '#8A7B6B'),
       ('bastard_sword', 'Bastard sword', '0e55221a-403b-490e-9509-062e2113d723', '{"TO": {"divisor": 5}, "WT": 4, "BK": 4}'::jsonb, false, 1002, false, 'sword', '#8A7B6B')
ON CONFLICT (agency_id, key) DO NOTHING;

UPDATE public.rpg_creatures c SET blueprint = c.blueprint || jsonb_build_object('BK', x.bk)
  FROM (VALUES ('dagger', 0), ('sling', 0), ('hand_axe', 1), ('sword', 2), ('quarterstaff', 2), ('crossbow', 2), ('spear', 3), ('flail', 3),
               ('battle_axe', 3), ('war_hammer', 3), ('longbow', 3), ('military_fork', 5), ('lance', 6),
               ('shield', 0), ('cloak', 0), ('armor', 0), ('trinket', 0), ('oil', 0), ('torch', 0)) AS x(key, bk)
 WHERE c.key = x.key AND c.parent_id = '0e55221a-403b-490e-9509-062e2113d723';

-- every thing already made from an object card gets the card's Bulk in its inputs (a fixed stat is read from them)
UPDATE public.rpg_characters c SET inputs = coalesce(c.inputs, '{}'::jsonb) || jsonb_build_object('BK', coalesce((k.blueprint->>'BK')::numeric, 0))
  FROM public.rpg_creatures k
 WHERE k.id = c.template_id AND k.parent_id = '0e55221a-403b-490e-9509-062e2113d723' AND NOT (coalesce(c.inputs, '{}'::jsonb) ? 'BK');

-- 2. The one home of the weapon in hand and its bulk.
CREATE OR REPLACE FUNCTION public.rpg_weapon_bulk(p_character_id uuid, p_stat_key text)
 RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $function$
-- The weapon in hand for a weapon skill and what its bulk costs: the first equipped, held, unbroken item whose card is
-- swung with that skill (item_id, item); its Bulk (bk on the object: a sword 2, a lance 6); the wielder's handling =
-- the levels of the basics the skill is built on (its formula's plus list) + (Strength + Agility) ÷ 10, whole part;
-- and over = bulk past the handling, 0 or more. Karen (Strength 10, Agility 1, basics 0) with a sword: bulk 2,
-- handling 1, over 1. No weapon in hand: item_id null, over 0. Read by rpg_act (the weapon), rpg_sheet (the stat's
-- 'bulk' and its "needs") and rpg_action_ticks (the swing's time). Internal.
DECLARE v_item record; v_vals jsonb; v_handling numeric := 0; v_f jsonb; v_e jsonb;
BEGIN
  SELECT i.id, i.name, coalesce((s->>'bk')::numeric, 0) AS bulk INTO v_item
    FROM public.rpg_items i CROSS JOIN LATERAL public.rpg_object_state(i.object_id) s
   WHERE i.character_id = p_character_id AND i.equipped AND NOT i.worn AND s->>'weapon_key' = p_stat_key AND NOT (s->>'broken')::boolean
   ORDER BY i.sort_order LIMIT 1;
  IF v_item.id IS NULL THEN RETURN jsonb_build_object('item_id', NULL, 'item', NULL, 'bulk', 0, 'handling', NULL, 'over', 0); END IF;
  v_vals := public.rpg_sheet_values(p_character_id)->'values';
  SELECT d.formula INTO v_f FROM public.rpg_stat_definitions d WHERE d.key = p_stat_key;
  FOR v_e IN SELECT e FROM jsonb_array_elements(coalesce(v_f->'plus', '[]'::jsonb)) e LOOP
    v_handling := v_handling + coalesce((v_vals->>(v_e->>0))::numeric, 0);
  END LOOP;
  v_handling := floor(v_handling + (coalesce((v_vals->>'ST')::numeric, 0) + coalesce((v_vals->>'AG')::numeric, 0)) / 10);
  RETURN jsonb_build_object('item_id', v_item.id, 'item', v_item.name, 'bulk', v_item.bulk, 'handling', v_handling,
                            'over', greatest(v_item.bulk - v_handling, 0));
END;
$function$;
REVOKE ALL ON FUNCTION public.rpg_weapon_bulk(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpg_weapon_bulk(uuid, text) TO service_role;

-- 3. rpg_action_ticks grows a third argument: the weapon skill of a swing, whose bulk past the handling lowers the
--    Speed the swing is figured at. The two-argument form is replaced in place (every old call still resolves).
DROP FUNCTION IF EXISTS public.rpg_action_ticks(uuid, numeric);
CREATE FUNCTION public.rpg_action_ticks(p_participant_id uuid, p_beats numeric, p_stat_key text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
-- Ticks an action of so many beats takes this fighter (rpg_ticks_at of beats × ticks_per_beat): the Bramblemaw's Claw
-- (1 beat) 12, its Bite (2 beats) 24; Karen's sword (2 beats) 36. A swing with a weapon skill (p_stat_key) whose weapon
-- is bulkier than the fighter handles is figured at 1 less Speed per point over, never under 0 (rpg_weapon_bulk):
-- Karen, Speed 1, sword 1 over → Speed 0, 40 ticks; Zaboo, Speed 5, lance 6 over → 40.
SELECT public.rpg_ticks_at(
         greatest(public.rpg_participant_speed(p_participant_id)
                  - CASE WHEN p_stat_key IS NULL THEN 0
                         ELSE coalesce((public.rpg_weapon_bulk((SELECT character_id FROM public.rpg_session_participants WHERE id = p_participant_id), p_stat_key)->>'over')::numeric, 0) END, 0),
         coalesce(p_beats, 0) * public.rpg_setting('ticks_per_beat'));
$function$;
REVOKE ALL ON FUNCTION public.rpg_action_ticks(uuid, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpg_action_ticks(uuid, numeric, text) TO service_role;

-- 4. Anchored patches.
CREATE FUNCTION pg_temp.rep(p_def text, p_old text, p_new text, p_label text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n integer := (length(p_def) - length(replace(p_def, p_old, ''))) / length(p_old);
BEGIN
  IF n <> 1 THEN RAISE EXCEPTION 'anchor % found % times', p_label, n; END IF;
  RETURN replace(p_def, p_old, p_new);
END $f$;

DO $do$
DECLARE v text; v_src text;
BEGIN
  -- rpg_act: patched by anchors; its md5 is checked first.
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_act';
  IF v_src NOT LIKE '%rpg_weapon_bulk%' THEN
    IF md5(v_src) <> '45ebf3c8035ca38d95aa90514d5c55c0' THEN RAISE EXCEPTION 'rpg_act body drifted (md5 %), patch by hand', md5(v_src); END IF;
    v := pg_get_functiondef('public.rpg_act(uuid,uuid[],text,uuid,text,numeric,integer,text)'::regprocedure);
    v := pg_temp.rep(v, $a$      SELECT i.id INTO v_weapon FROM public.rpg_items i CROSS JOIN LATERAL public.rpg_object_state(i.object_id) s
       WHERE i.character_id = v_actor.character_id AND i.equipped AND NOT i.worn AND s->>'weapon_key' = p_stat_key AND NOT (s->>'broken')::boolean
       ORDER BY i.sort_order LIMIT 1;$a$,
$b$      v_weapon := (public.rpg_weapon_bulk(v_actor.character_id, p_stat_key)->>'item_id')::uuid;$b$, 'act weapon lookup');
    v := pg_temp.rep(v, $a$        v_who := v_actor.name || ' attacks ' || v_t.name || ' with ' || v_label;$a$,
$b$        v_who := v_actor.name || ' attacks ' || v_t.name || ' with ' || v_label
                 || CASE WHEN coalesce((v_first->>'bulk_over')::integer, 0) > 0 THEN ' (bulk ' || (v_first->>'bulk_over') || ' over: rolls as ' || trim_scale((v_first->>'skill')::numeric) || ')' ELSE '' END;$b$, 'act who bulk');
    v := pg_temp.rep(v, $a$    UPDATE public.rpg_sessions SET turn_action_ticks = public.rpg_action_ticks(p_actor_id, v_beats) WHERE id = v_s.id;$a$,
$b$    UPDATE public.rpg_sessions SET turn_action_ticks = public.rpg_action_ticks(p_actor_id, v_beats, CASE WHEN v_kind = 'attack' THEN p_stat_key END) WHERE id = v_s.id;$b$, 'act swing ticks');
    EXECUTE v;
  END IF;

  -- rpg_sheet: patched by anchors; its md5 is checked first.
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_sheet';
  IF v_src NOT LIKE '%rpg_weapon_bulk%' THEN
    IF md5(v_src) <> '4e3d0e12f825d5f6b6232a86e0f6c087' THEN RAISE EXCEPTION 'rpg_sheet body drifted (md5 %), patch by hand', md5(v_src); END IF;
    v := pg_get_functiondef('public.rpg_sheet(uuid,numeric)'::regprocedure);
    v := pg_temp.rep(v, $a$  v_sections jsonb;$a$,
$b$  v_sections jsonb;
  v_bulk    jsonb;$b$, 'sheet declare');
    v := pg_temp.rep(v, $a$    v_nc := public.rpg_needed(v_v, v_diff + CASE WHEN v_d.spirit_discipline THEN coalesce(v_c.spiritual_burden, 0) ELSE 0 END);$a$,
$b$    -- a weapon skill with a bulky weapon in hand rolls lower by the bulk past the handling (rpg_weapon_bulk), so its "needs" says so too
    v_bulk := CASE WHEN v_d.is_attack THEN public.rpg_weapon_bulk(p_character_id, v_d.key) END;
    v_nc := public.rpg_needed(greatest(v_v - coalesce((v_bulk->>'over')::numeric, 0), 0), v_diff + CASE WHEN v_d.spirit_discipline THEN coalesce(v_c.spiritual_burden, 0) ELSE 0 END);$b$, 'sheet needed');
    v := pg_temp.rep(v, $a$      'needed', v_nc->'needed', 'critical', v_nc->'critical',$a$,
$b$      'needed', v_nc->'needed', 'critical', v_nc->'critical', 'bulk', v_bulk,$b$, 'sheet bulk key');
    EXECUTE v;
  END IF;

  -- rpg_roll: patched by anchors; its md5 is checked first.
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_roll';
  IF v_src NOT LIKE '%bulk_over%' THEN
    IF md5(v_src) <> 'e84c57be58094aad4998d95022642313' THEN RAISE EXCEPTION 'rpg_roll body drifted (md5 %), patch by hand', md5(v_src); END IF;
    v := pg_get_functiondef('public.rpg_roll(uuid,text,numeric,text,uuid,uuid,uuid,integer)'::regprocedure);
    v := pg_temp.rep(v, $a$v_trainable boolean := false;
BEGIN$a$,
$b$v_trainable boolean := false; v_over integer := 0;
BEGIN$b$, 'roll declare');
    v := pg_temp.rep(v, $a$  v_trainable := coalesce((v_stat->>'trainable')::boolean, false);$a$,
$b$  v_trainable := coalesce((v_stat->>'trainable')::boolean, false);
  -- a bulky weapon in hand: each point of its bulk past the roller's handling takes 1 off the skill for this swing (the
  -- sheet carries it as the stat's 'bulk', from rpg_weapon_bulk); the level climbed from is still the sheet's
  v_over := coalesce((v_stat->'bulk'->>'over')::integer, 0);
  v_skill := greatest(v_skill - v_over, 0);$b$, 'roll bulk');
    v := pg_temp.rep(v, $a$  v_before := v_skill::integer; v_after := v_before;$a$,
$b$  v_before := (v_stat->>'value')::numeric::integer; v_after := v_before;$b$, 'roll level before');
    v := pg_temp.rep(v, $a$    'level_before', v_before, 'level_after', v_after, 'grew', v_grew, 'discipline', v_disc, 'extra_pending', v_result = 'C', 'manual', p_roll IS NOT NULL,$a$,
$b$    'level_before', v_before, 'level_after', v_after, 'grew', v_grew, 'discipline', v_disc, 'bulk_over', v_over, 'extra_pending', v_result = 'C', 'manual', p_roll IS NOT NULL,$b$, 'roll return');
    EXECUTE v;
  END IF;

  -- rpg_session_state: patched by anchors; its md5 is checked first.
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_session_state';
  IF v_src NOT LIKE '%bulk%' THEN
    IF md5(v_src) <> '879f5fc512c8576a4f5f6612b3d6930e' THEN RAISE EXCEPTION 'rpg_session_state body drifted (md5 %), patch by hand', md5(v_src); END IF;
    v := pg_get_functiondef('public.rpg_session_state(uuid)'::regprocedure);
    v := pg_temp.rep(v, $a$        'weapons', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', s->>'key', 'name', s->>'name', 'value', s->'value', 'beats', d.beats, 'ticks', public.rpg_action_ticks(v_p.id, d.beats), 'energy_cost', d.energy_cost, 'energy_type', d.energy_type, 'reach', d.reach)$a$,
$b$        'weapons', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', s->>'key', 'name', s->>'name', 'value', s->'value', 'beats', d.beats, 'ticks', public.rpg_action_ticks(v_p.id, d.beats, s->>'key'), 'energy_cost', d.energy_cost, 'energy_type', d.energy_type, 'reach', d.reach, 'bulk', s->'bulk')$b$, 'state weapons bulk');
    EXECUTE v;
  END IF;

  -- rpg_object_state: patched by anchors; its md5 is checked first.
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_object_state';
  IF v_src NOT LIKE '%->> ''BK''%' THEN
    IF md5(v_src) <> '68f0b346972b2521ebe8fb34097a168b' THEN RAISE EXCEPTION 'rpg_object_state body drifted (md5 %), patch by hand', md5(v_src); END IF;
    v := pg_get_functiondef('public.rpg_object_state(uuid)'::regprocedure);
    v := pg_temp.rep(v, $a$    'ig', coalesce((v -> 'values' ->> 'IG')::numeric, 0), 'wt', coalesce((v -> 'values' ->> 'WT')::numeric, 0),$a$,
$b$    'ig', coalesce((v -> 'values' ->> 'IG')::numeric, 0), 'wt', coalesce((v -> 'values' ->> 'WT')::numeric, 0), 'bk', coalesce((v -> 'values' ->> 'BK')::numeric, 0),$b$, 'object bk');
    EXECUTE v;
  END IF;

  -- rpg_item_row: patched by anchors; its md5 is checked first.
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_item_row';
  IF v_src NOT LIKE '%s->''bk''%' THEN
    IF md5(v_src) <> '21080fe5973e342f00afc138e35fc34e' THEN RAISE EXCEPTION 'rpg_item_row body drifted (md5 %), patch by hand', md5(v_src); END IF;
    v := pg_get_functiondef('public.rpg_item_row(uuid)'::regprocedure);
    v := pg_temp.rep(v, $a$         'life', s->'pv', 'life_left', s->'left', 'broken', s->'broken', 'integrity', s->'ig', 'weight', s->'wt',$a$,
$b$         'life', s->'pv', 'life_left', s->'left', 'broken', s->'broken', 'integrity', s->'ig', 'weight', s->'wt', 'bulk', s->'bk',$b$, 'item bulk');
    EXECUTE v;
  END IF;

END $do$;

-- 5. Rule card (the manual page follows by trigger).
DO $do$
DECLARE v text;
BEGIN
  SELECT body INTO v FROM public.rpg_rules WHERE key = 'items';
  v := pg_temp.rep(v, $a$Weight counts toward burden: Strength × 2 is carried free, and every point past it lowers Evade Enemy by one (Strength 10 carries 20).$a$,
$b$Weight counts toward burden: Strength × 2 is carried free, and every point past it lowers Evade Enemy by one (Strength 10 carries 20).

Bulk is how hard a thing is to move quickly because of its length and balance, a set number on its card: a dagger 0, a sword 2, a spear or longbow 3, a long sword 3, a bastard sword 4, a military fork 5, a lance 6. Weight is met by muscle; bulk is met by handling: the levels of the basics the weapon's skill is built on (Swing arm, Grip and Footwork for a sword; Grip, Aim and Breath for a bow) plus (Strength + Agility) ÷ 10, whole part. Every swing trains those basics, so a weapon gets easier with practice. Each point of bulk past your handling takes 1 off the weapon skill for that swing and makes the swing slower, figured at 1 less Speed.
*Karen (Strength 10, Agility 1, basics 0) handles 1. Her sword is 2 bulk: 1 over, so Sword 6 rolls as 5 and the swing is figured at Speed 0, 40 ticks instead of 36. Zaboo (Strength 5, Agility 3) handles 0; a lance is 6 over, so his Spear 5 rolls as 0 and the swing takes 40 ticks: he cannot fight with it yet.*$b$, 'items bulk');
  UPDATE public.rpg_rules SET body = v WHERE key = 'items';
END $do$;

