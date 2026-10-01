
-- Roleplaying skill tree step 2 (Peter 2026-10-01 decisions 1A 2A 3B): the creation fill, the creature cards retuned
-- for it, shut skills off the sheet and refused by rpg_roll, the four player characters filled once, rule cards.

-- 1. rpg_creation_fill: decision 2A, the one home of the creation fill
CREATE OR REPLACE FUNCTION public.rpg_creation_fill(p_character_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
-- The creation fill (Peter 2026-10-01, decision 2A). A new being gets exactly enough points, roots first, to open every
-- skill a fight or a prayer rolls: its fighting and spiritual skills (every weapon, the armor of God, Prayer, Bible
-- Study, both Healings, a card's own attacks) and every stat a card action rolls or is rolled against (Evade Enemy,
-- Courage, Listening). Open and shut come from rpg_skill_tree, the one home of the tree. Each pass takes the shut skill
-- with the lowest bar whose parents are all open, and pays each parent under a third of its own bar exactly what the
-- level ladder costs to reach it (rpg_add_skill_points, the one writer of banked points), less what it has banked.
-- A new Human has every basic at 0: each needs 1,000 points to reach 1, and that opens all of them (Sword opens at
-- Courage 1, Endurance 1, Solo Battle 2, Swing arm 1, Grip 1, Footwork 1). Every other skill opens through play.
-- Returns {stat: points spent}. Called at the end of rpg_apply_experience (new beings and re-rolls). Internal.
DECLARE
  v_card    uuid;
  v_targets text[];
  v_need    text[];
  v_more    text[];
  v_vals    jsonb;
  v_tree    jsonb;
  v_node    text;
  v_p       text;
  v_t       integer;
  v_cost    numeric;
  v_bank    numeric;
  v_pass    integer := 0;
  v_spent   jsonb := '{}'::jsonb;
BEGIN
  SELECT template_id INTO v_card FROM public.rpg_characters WHERE id = p_character_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'character not found'; END IF;
  v_targets := ARRAY(
    SELECT d.key FROM public.rpg_template_stat_defs(v_card) d
     WHERE d.trainable
       AND (d.grp IN ('fighting', 'spiritual')
            OR d.key IN (SELECT x FROM public.rpg_creature_actions a,
                           LATERAL (VALUES (a.skill_key), (a.against),
                                           (a.effect -> 'contest' ->> 'skill_key'), (a.effect -> 'contest' ->> 'against'),
                                           (a.effect -> 'apply' ->> 'check_stat'),
                                           (a.effect -> 'ended_by' ->> 'skill_key'), (a.effect -> 'ended_by' ->> 'against')) v(x)
                          WHERE a.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND x IS NOT NULL)));
  LOOP
    v_pass := v_pass + 1;
    EXIT WHEN v_pass > 60;
    v_vals := public.rpg_sheet_values(p_character_id) -> 'values';
    v_tree := public.rpg_skill_tree(v_card, v_vals);
    IF v_need IS NULL THEN
      -- the targets and everything they are built on
      v_need := ARRAY(SELECT k FROM unnest(v_targets) k WHERE v_tree ? k);
      LOOP
        v_more := ARRAY(SELECT DISTINCT p FROM unnest(v_need) k, jsonb_array_elements_text(coalesce(v_tree -> k -> 'parents', '[]'::jsonb)) p
                         WHERE NOT p = ANY (v_need));
        EXIT WHEN cardinality(v_more) = 0;
        v_need := v_need || v_more;
      END LOOP;
    END IF;
    v_node := NULL;
    SELECT k INTO v_node FROM unnest(v_need) k
     WHERE NOT (v_tree -> k ->> 'open')::boolean
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_tree -> k -> 'parents') p WHERE NOT (v_tree -> p ->> 'open')::boolean)
     ORDER BY (v_tree -> k ->> 'bar')::integer, k LIMIT 1;
    EXIT WHEN v_node IS NULL;
    FOR v_p IN SELECT jsonb_array_elements_text(v_tree -> v_node -> 'parents') LOOP
      v_t := (v_tree -> v_p ->> 'bar')::integer / 3;
      CONTINUE WHEN coalesce((v_vals ->> v_p)::numeric, 0) >= v_t;
      SELECT coalesce(sum(public.rpg_level_cost(l)), 0) INTO v_cost
        FROM generate_series(coalesce((v_vals ->> v_p)::numeric, 0)::integer, v_t - 1) l;
      SELECT coalesce(max(skill_points), 0) INTO v_bank FROM public.rpg_character_skills
       WHERE character_id = p_character_id AND stat_key = v_p;
      v_cost := greatest(v_cost - v_bank, 0);
      PERFORM public.rpg_add_skill_points(p_character_id, v_p, v_cost, coalesce((v_vals ->> v_p)::numeric, 0));
      v_spent := v_spent || jsonb_build_object(v_p, coalesce((v_spent ->> v_p)::numeric, 0) + v_cost);
    END LOOP;
  END LOOP;
  RETURN v_spent;
END;
$f$;
REVOKE ALL ON FUNCTION public.rpg_creation_fill(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_creation_fill(uuid) TO service_role;

-- 2-4. anchored patches (each body checked against the one read before writing)
DO $do$
DECLARE
  v_oid regprocedure; v_src text; v_def text; v_n integer; v_i integer;
  v_jobs jsonb := jsonb_build_array(
    jsonb_build_object('fn', 'public.rpg_apply_experience(uuid,uuid)', 'md5', '248de58ae0046189bee3fb8fc31ad91f', 'pairs', jsonb_build_array(
      jsonb_build_array($a$     ORDER BY d.sort_order NULLS LAST, b.key$a$,
                        $a$     ORDER BY (d.kind IN ('rolled', 'fixed')) DESC NULLS LAST, (d.grp = 'basic') DESC NULLS LAST, d.sort_order NULLS LAST, b.key$a$),
      jsonb_build_array($a$-- Used by rpg_new_character and rpg_reroll_character.$a$,
                        $a$-- Basics go before the skills built on them (roots first), so a skill climbs with its basics already in.
-- Afterwards rpg_creation_fill opens every skill a fight or a prayer rolls (decision 2A).
-- Used by rpg_new_character and rpg_reroll_character.$a$),
      jsonb_build_array($a$  END LOOP;
END;$a$, $a$  END LOOP;
  PERFORM public.rpg_creation_fill(p_character_id);
END;$a$))),
    jsonb_build_object('fn', 'public.rpg_sheet(uuid,numeric)', 'md5', 'fd49fca73009121e2153080873770d61', 'pairs', jsonb_build_array(
      jsonb_build_array($a$    CONTINUE WHEN v_d.side = 'evil' OR v_d.grp = 'basic';$a$,
                        $a$    CONTINUE WHEN v_d.side = 'evil' OR v_d.grp = 'basic';
    -- a shut skill is not on the sheet (rpg_skill_tree: a parent not yet open, or under a third of its own bar)
    CONTINUE WHEN v_d.trainable AND v_tree ? v_d.key AND NOT (v_tree -> v_d.key ->> 'open')::boolean;$a$))),
    jsonb_build_object('fn', 'public.rpg_roll(uuid,text,numeric,text,uuid,uuid,uuid,integer)', 'md5', '5e3206587b97faa5dcae39ed2a593041', 'pairs', jsonb_build_array(
      jsonb_build_array($a$  IF v_stat IS NULL THEN RAISE EXCEPTION 'unknown stat %', p_stat_key; END IF;$a$,
                        $a$  IF v_stat IS NULL THEN
    -- the sheet leaves a shut skill out (rpg_skill_tree), so rolling one is refused by name: Sword with Grip at 0
    SELECT d.name INTO v_name FROM public.rpg_characters c
     CROSS JOIN LATERAL public.rpg_template_stat_defs(c.template_id) d
     WHERE c.id = p_character_id AND d.key = p_stat_key
       AND (public.rpg_skill_tree(c.template_id, public.rpg_sheet_values(c.id) -> 'values') -> d.key ->> 'open') = 'false';
    IF v_name IS NOT NULL THEN
      RAISE EXCEPTION '% is not open yet: every skill it is built on must be open and at a third of its own bar', v_name;
    END IF;
    RAISE EXCEPTION 'unknown stat %', p_stat_key;
  END IF;$a$))));
  v_job jsonb; v_pair jsonb;
BEGIN
  FOR v_job IN SELECT * FROM jsonb_array_elements(v_jobs) LOOP
    v_oid := (v_job ->> 'fn')::regprocedure;
    SELECT p.prosrc, pg_get_functiondef(p.oid) INTO v_src, v_def FROM pg_proc p WHERE p.oid = v_oid;
    IF md5(v_src) <> v_job ->> 'md5' THEN RAISE EXCEPTION '% changed since it was read', v_job ->> 'fn'; END IF;
    FOR v_pair IN SELECT * FROM jsonb_array_elements(v_job -> 'pairs') LOOP
      v_n := (length(v_def) - length(replace(v_def, v_pair ->> 0, ''))) / length(v_pair ->> 0);
      IF v_n <> 1 THEN RAISE EXCEPTION '% anchor found % times: %', v_job ->> 'fn', v_n, left(v_pair ->> 0, 60); END IF;
      v_def := replace(v_def, v_pair ->> 0, v_pair ->> 1);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$do$;

-- 5. the creature cards retuned so their sheets hold with the fill (sandbox simulation, paired rolls; Bramblemaw exact)
UPDATE public.rpg_creatures SET blueprint = (blueprint - 'EE' - 'claw') || '{"CO": {"points": 17000}}'::jsonb
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'bramblemaw';
UPDATE public.rpg_creatures SET blueprint = (blueprint - 'CO') || '{"EE": {"points": 15000}, "hunting_screech": {"points": 9000}}'::jsonb
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'ashwing_harrier';
UPDATE public.rpg_creatures SET blueprint = blueprint || '{"CO": {"points": 39000}, "EE": {"points": 84000}}'::jsonb
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'mossback_elder';
UPDATE public.rpg_creatures SET blueprint = blueprint || '{"CO": {"points": 19000}, "EE": {"points": 17000}}'::jsonb
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'gloam_wisp';
UPDATE public.rpg_creatures SET blueprint = blueprint || '{"CO": {"points": 11000}, "EE": {"points": 11000}}'::jsonb
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'thornfield_boar';

-- 6. the four player characters, filled once (decision 2A: no re-roll)
SELECT public.rpg_creation_fill(id) FROM public.rpg_characters
 WHERE id IN ('042747fa-ee70-4fd1-80a2-2e0191673657', 'e3b7fa8f-bc11-4503-a1a0-8071a8526b57',
              '7d212908-e52d-423f-81bb-cc4dcd44c133', '7da511dc-732a-47b5-b309-7cd5acb365e8');

-- 7. rule cards
INSERT INTO public.rpg_rules (agency_id, key, title, body, source, sort_order, section)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'skill_tree', 'The Skill Tree',
$r$Every skill is built from other things on the sheet. The skills and basics it is built from are its parents; traits such as Strength or Love are never parents. A skill with no parent skill is a root: every basic (Grip, Trust), and a skill built only from traits (Hope).

Every skill has a mastery bar. A root's bar is 3. Any other skill's bar is the sum of its parents' bars.
*Courage is built on Trust (bar 3), so its bar is 3. Solo Battle is built on Courage and Endurance: 3 + 3 = 6. Sword is built on Courage, Endurance, Solo Battle, Swing arm, Grip and Footwork: 3 + 3 + 6 + 3 + 3 + 3 = 21.*

A skill is open when every parent is open and each parent stands at a third of its own bar or more, rounded down. A skill that is not open is shut: it is not on the sheet and cannot be rolled. A root is always open.
*Sword opens at Courage 1, Endurance 1, Solo Battle 2, Swing arm 1, Grip 1 and Footwork 1. With Grip at 0, Sword is shut.*

A new being gets exactly enough points, from the roots up, to open every skill a fight or a prayer rolls: every weapon, Evade Enemy, the armor of God, Prayer, Bible Study, both Healings, and every skill a creature's card rolls or is rolled against. Every other skill opens through play, as its parents grow.
*A new Human starts with every basic at 0, so each gets 1,000 points and reaches 1, and that opens all of them. Karen got the same once: her Sword went from 6 to 8, 1 from the average of Swing arm, Grip and Footwork, and 1 because Trust and Breath lifted Courage from 8 to 9 and Endurance from 7 to 8.*$r$,
 'peter', 66, 'Getting Better');

UPDATE public.rpg_rules SET body =
$r$Every weapon and spiritual skill is built on a few basics that never show on the sheet: Swing arm, Grip, Aim, Footwork, Brace and Breath for the body; Stillness, Attention and Trust for the spirit. A new being's basics start at 0 and get exactly the points that open its fighting and prayer skills, which takes each to 1 (see The Skill Tree). A basic climbs the same level ladder as a skill (0 to 1 costs 1,000 points, 1 to 2 costs 3,000), and the basics under a skill add their average to it, rounded down.
*Sword is (Courage + Endurance + Solo Battle + Agility + Strength) ÷ 5, rounded down, plus the average of Swing arm, Grip and Footwork, rounded down. With only Footwork at 1 the average is 0.33, which adds nothing. With all three at 1 it adds 1; with all three at 2 it adds 2.*

Points trickle down. When a roll pays a skill, half as much flows down to what the skill is built from, split by weight, and each part passes half of its share on down to its own parts. A basic or a trainable skill banks what reaches it. A trait (Strength, Focus, Love) banks it too and climbs one whole level when the bank covers the ladder, with the Spirit pair rules as always.
*Karen rolls a 60 with her Sword 8 against difficulty 5 (Needed 38.46): the Sword gets 23 points and 11.5 flows down, about 1.4 each to Courage, Endurance, Solo Battle, Agility, Strength, Swing arm, Grip and Footwork. Courage passes 0.7 on to what it is built from. Her Swing arm 1 to 2 costs 3,000 points, about 2,100 swings. Strength 10 to 11 costs 21,000 points, about 14,600 swings.*$r$,
 updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'basics';

UPDATE public.rpg_rules SET body = replace(replace(body,
  $r$and then the card's experience is spent up the same level ladder.$r$,
  $r$and then the card's experience is spent up the same level ladder, and like every new being it gets the points that open the skills a fight rolls (see The Skill Tree).$r$),
  $r$= 9, rounded down, and its card's experience adds one level: Claw 10.$r$,
  $r$= 9, rounded down, plus its Rake 1: Claw 10.$r$),
 updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'creature_conversion';

