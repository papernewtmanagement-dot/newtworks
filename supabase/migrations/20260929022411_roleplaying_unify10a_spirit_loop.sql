-- roleplaying_unify10a_spirit_loop
-- The spirit loop (Peter 2026-09-29, "defaults" = 1A 2A 3A 4A). Prayer and Bible Study are skills on the sheet, rolled
-- and trained like any other; their points trickle to Connection with God and the armor of God (the five pieces are
-- trainable now). Spiritual burden is set by the game master from the sheet; it raises the two disciplines' difficulty
-- and lowers the Boots evade in a fight, and a successful discipline works it off. The Shield of Faith has a life of
-- 3 × its value, takes the strength of every spiritual attack it stops, and is restored by the disciplines. Broken
-- physical items are repaired from the sheet at 1 silver a point of life, paid from the owner's coins.

-- 1. The two disciplines and the trainable armor
ALTER TABLE public.rpg_stat_definitions ADD COLUMN IF NOT EXISTS spirit_discipline boolean NOT NULL DEFAULT false;
INSERT INTO public.rpg_stat_definitions
  (agency_id, key, name, abbr, grp, kind, trainable, formula, default_value, sort_order, is_attack, beats, energy_cost, energy_type, template_id, spirit_discipline)
SELECT '126794dd-25ff-47d2-a436-724499733365', v.key, v.name, v.abbr, 'spiritual', 'derived', true, v.formula::jsonb, 0, v.sort_order, false, 2, 3, 'spiritual', c.id, true
  FROM (VALUES
    ('prayer',      'Prayer',      'PRY', '{"div": 5, "parts": [["CG", 2], ["FA", 1], ["SF", 1], ["BR", 1]], "plus": [["stillness", 1], ["trust", 1]]}', 260),
    ('bible_study', 'Bible Study', 'BIB', '{"div": 6, "parts": [["CG", 2], ["KN", 1], ["BT", 1], ["HS", 1], ["BGP", 1]], "plus": [["attention", 1]]}', 261)
  ) AS v(key, name, abbr, formula, sort_order)
  JOIN public.rpg_creatures c ON c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.key = 'creature'
ON CONFLICT (agency_id, key) DO NOTHING;
UPDATE public.rpg_stat_definitions SET trainable = true
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key IN ('BT', 'BR', 'SF', 'HS', 'BGP');

-- 2. The Shield of Faith's wear lives on the character
ALTER TABLE public.rpg_characters ADD COLUMN IF NOT EXISTS spirit_wear jsonb NOT NULL DEFAULT '{}'::jsonb;

-- 3. The Shield of Faith: its life, its wear, one home
CREATE OR REPLACE FUNCTION public.rpg_shield_state(p_character_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  -- The Shield of Faith has a life of 3 × its value (a Shield of Faith 6 has 18). The wear it has taken sits in
  -- rpg_characters.spirit_wear->>'SF'. Broken (nothing left) it blocks nothing until Prayer or Bible Study restore it.
  -- Read by rpg_act, rpg_sheet and rpg_shield_wear. Internal.
  SELECT jsonb_build_object('value', x.sf, 'life', x.life, 'wear', x.wear, 'left', greatest(x.life - x.wear, 0), 'broken', x.wear >= x.life)
    FROM (SELECT coalesce((sv -> 'values' ->> 'SF')::numeric, 0) AS sf,
                 3 * coalesce((sv -> 'values' ->> 'SF')::numeric, 0) AS life,
                 coalesce((c.spirit_wear ->> 'SF')::numeric, 0) AS wear
            FROM public.rpg_characters c CROSS JOIN LATERAL public.rpg_sheet_values(c.id) sv
           WHERE c.id = p_character_id) x;
$fn$;
REVOKE ALL ON FUNCTION public.rpg_shield_state(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.rpg_shield_wear(p_character_id uuid, p_delta integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
-- Wears (+) or restores (−) the Shield of Faith; its wear stays between 0 and its life. A shield with 18 life that has
-- taken 15 and now takes 8 → 0 left, broke; restored by 20 → 18 of 18. Returns {life, taken, restored, left, broke}.
-- Used by rpg_act (a blocked spiritual attack) and rpg_discipline_effects (Prayer, Bible Study). Internal.
DECLARE v_s jsonb; v_wear numeric; v_new numeric;
BEGIN
  v_s := public.rpg_shield_state(p_character_id);
  v_wear := (v_s ->> 'wear')::numeric;
  v_new := least(greatest(v_wear + coalesce(p_delta, 0), 0), (v_s ->> 'life')::numeric);
  UPDATE public.rpg_characters SET spirit_wear = spirit_wear || jsonb_build_object('SF', v_new) WHERE id = p_character_id;
  RETURN jsonb_build_object('life', (v_s ->> 'life')::numeric, 'taken', greatest(v_new - v_wear, 0), 'restored', greatest(v_wear - v_new, 0),
                            'left', (v_s ->> 'life')::numeric - v_new,
                            'broke', v_new >= (v_s ->> 'life')::numeric AND v_wear < (v_s ->> 'life')::numeric);
END;
$fn$;
REVOKE ALL ON FUNCTION public.rpg_shield_wear(uuid, integer) FROM PUBLIC, anon, authenticated;

-- 4. What a successful Prayer or Bible Study does besides its points
CREATE OR REPLACE FUNCTION public.rpg_discipline_effects(p_character_id uuid, p_strength numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
-- A successful Prayer or Bible Study (strength = its die minus what it needed, like a blow's damage) works off the
-- burden of sins and bad decisions by strength ÷ 10 rounded up, at least 1 (a 70 needing 50 works off 2), and restores
-- the Shield of Faith by the strength (20 back). Returns {burden_before, burden_after, burden_off, shield_restored,
-- shield_left, text}; the text is what the log and the sheet say. Called by rpg_roll. Internal.
DECLARE v_c record; v_off integer; v_after integer; v_w jsonb; v_text text := '';
BEGIN
  SELECT * INTO v_c FROM public.rpg_characters WHERE id = p_character_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'character not found'; END IF;
  v_off := least(greatest(ceil(coalesce(p_strength, 0) / 10.0)::integer, 1), coalesce(v_c.spiritual_burden, 0));
  v_after := coalesce(v_c.spiritual_burden, 0) - v_off;
  IF v_off > 0 THEN
    UPDATE public.rpg_characters SET spiritual_burden = v_after WHERE id = p_character_id;
    v_text := v_c.name || '''s burden eases by ' || v_off || CASE WHEN v_after = 0 THEN ', none left.' ELSE ', ' || v_after || ' left.' END;
  END IF;
  v_w := public.rpg_shield_wear(p_character_id, -floor(greatest(coalesce(p_strength, 0), 0))::integer);
  IF (v_w ->> 'restored')::numeric > 0 THEN
    v_text := btrim(v_text || ' The Shield of Faith is restored by ' || (v_w ->> 'restored')::numeric::integer
              || ', ' || (v_w ->> 'left')::numeric::integer || ' of ' || (v_w ->> 'life')::numeric::integer || '.');
  END IF;
  RETURN jsonb_build_object('burden_before', coalesce(v_c.spiritual_burden, 0), 'burden_after', v_after, 'burden_off', v_off,
                            'shield_restored', v_w -> 'restored', 'shield_left', v_w -> 'left', 'text', v_text);
END;
$fn$;
REVOKE ALL ON FUNCTION public.rpg_discipline_effects(uuid, numeric) FROM PUBLIC, anon, authenticated;

-- 5. The game master sets the burden from the sheet
CREATE OR REPLACE FUNCTION public.rpg_adjust_burden(p_character_id uuid, p_delta integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
-- Spiritual burden, the weight of sins and bad decisions: the game master adds or takes 1 from the sheet. It never
-- goes below 0. In a fight it lowers the Boots of the Gospel of Peace evade by its amount; it raises the difficulty
-- of Prayer and Bible Study by its amount (rpg_roll); a successful Prayer or Bible Study works it off
-- (rpg_discipline_effects). Parents only. Returns the sheet.
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master sets a burden'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rpg_characters WHERE id = p_character_id) THEN RAISE EXCEPTION 'character not found'; END IF;
  UPDATE public.rpg_characters SET spiritual_burden = greatest(coalesce(spiritual_burden, 0) + coalesce(p_delta, 0), 0) WHERE id = p_character_id;
  RETURN public.rpg_sheet(p_character_id);
END;
$fn$;
GRANT EXECUTE ON FUNCTION public.rpg_adjust_burden(uuid, integer) TO authenticated, service_role;

-- 6. Paying, and repairing an item
CREATE OR REPLACE FUNCTION public.rpg_coins_text(p_copper bigint)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  -- An amount in copper spelled in the largest coins: 3,020 copper is "30 silver 20 copper", 1,000,000 is "1 platinum".
  SELECT coalesce(nullif(concat_ws(' ',
    CASE WHEN p_copper / 1000000 > 0 THEN (p_copper / 1000000) || ' platinum' END,
    CASE WHEN (p_copper % 1000000) / 10000 > 0 THEN ((p_copper % 1000000) / 10000) || ' gold' END,
    CASE WHEN (p_copper % 10000) / 100 > 0 THEN ((p_copper % 10000) / 100) || ' silver' END,
    CASE WHEN p_copper % 100 > 0 THEN (p_copper % 100) || ' copper' END), ''), '0 copper');
$fn$;

CREATE OR REPLACE FUNCTION public.rpg_pay(p_character_id uuid, p_copper bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
-- Pays from a character's coins. 1 platinum = 100 gold, 1 gold = 100 silver, 1 silver = 100 copper (the Currency
-- card). The coins are counted in copper, the price taken, and what is left dealt back into the largest coins
-- (2 gold 50 silver after paying 30 silver is 2 gold 20 silver). Refused, naming the price and what they have, when
-- short. Returns the coins after. The one place a price is paid; used by rpg_item_repair. Internal.
DECLARE v_c record; v_total bigint; v_left bigint;
BEGIN
  SELECT * INTO v_c FROM public.rpg_characters WHERE id = p_character_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'character not found'; END IF;
  v_total := coalesce(v_c.platinum, 0)::bigint * 1000000 + coalesce(v_c.gold, 0)::bigint * 10000
           + coalesce(v_c.silver, 0)::bigint * 100 + coalesce(v_c.copper, 0)::bigint;
  IF v_total < coalesce(p_copper, 0) THEN
    RAISE EXCEPTION '% needs % and has %', v_c.name, public.rpg_coins_text(p_copper), public.rpg_coins_text(v_total);
  END IF;
  v_left := v_total - coalesce(p_copper, 0);
  UPDATE public.rpg_characters
     SET platinum = (v_left / 1000000)::integer, gold = ((v_left % 1000000) / 10000)::integer,
         silver = ((v_left % 10000) / 100)::integer, copper = (v_left % 100)::integer
   WHERE id = p_character_id;
  RETURN jsonb_build_object('paid', p_copper, 'paid_text', public.rpg_coins_text(p_copper), 'left_text', public.rpg_coins_text(v_left));
END;
$fn$;
REVOKE ALL ON FUNCTION public.rpg_pay(uuid, bigint) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.rpg_item_repair(p_item_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
-- Repairs an item in full, the shop with the game master at the counter: 1 silver for every point of life restored,
-- paid from the owner's coins (rpg_pay). A dagger with 30 of 47 life missing costs 30 silver; an owner who cannot pay
-- is refused with the price and what they have. Parents only. Returns the owner's sheet.
DECLARE v_i record; v_s jsonb; v_missing integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master runs the shop'; END IF;
  SELECT * INTO v_i FROM public.rpg_items WHERE id = p_item_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'item not found'; END IF;
  v_s := public.rpg_object_state(v_i.object_id);
  v_missing := (v_s ->> 'pv')::integer - (v_s ->> 'left')::integer;
  IF v_missing <= 0 THEN RAISE EXCEPTION '% needs no repair', v_i.name; END IF;
  PERFORM public.rpg_pay(v_i.character_id, v_missing::bigint * 100);
  UPDATE public.rpg_characters SET vitality_damage = 0 WHERE id = v_i.object_id;
  RETURN public.rpg_sheet(v_i.character_id);
END;
$fn$;
GRANT EXECUTE ON FUNCTION public.rpg_item_repair(uuid) TO authenticated, service_role;

-- 7. rpg_roll: a discipline faces the burden and, on a success, eases it and restores the shield (patched by anchors)
DO $do$
DECLARE v_src text; v_n int;
BEGIN
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_roll';
  IF v_src LIKE '%rpg_discipline_effects%' THEN RETURN; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, 'v_points numeric := 0; v_before integer; v_after integer; v_grew jsonb := ''\{\}''::jsonb;', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_roll anchor 1 found % times', v_n; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '  v_trainable := coalesce\(\(v_stat->>''trainable''\)::boolean, false\);\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_roll anchor 2 found % times', v_n; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '    v_grew := public\.rpg_trickle\(p_character_id, p_stat_key, v_points\);\n  END IF;\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_roll anchor 3 found % times', v_n; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '''grew'', v_grew, ', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_roll anchor 4 found % times', v_n; END IF;
  v_src := replace(v_src, 'v_points numeric := 0; v_before integer; v_after integer; v_grew jsonb := ''{}''::jsonb;',
                          'v_points numeric := 0; v_before integer; v_after integer; v_grew jsonb := ''{}''::jsonb; v_discipline boolean := false; v_burden integer := 0; v_disc jsonb := NULL;');
  v_src := replace(v_src, E'  v_trainable := coalesce((v_stat->>''trainable'')::boolean, false);\n',
                          E'  v_trainable := coalesce((v_stat->>''trainable'')::boolean, false);\n  -- Prayer and Bible Study: the burden of sins and bad decisions raises their difficulty by its amount (burden 6: 5 becomes 11)\n  SELECT coalesce(d.spirit_discipline, false) INTO v_discipline FROM public.rpg_stat_definitions d WHERE d.key = p_stat_key;\n  IF v_discipline THEN\n    SELECT coalesce(spiritual_burden, 0) INTO v_burden FROM public.rpg_characters WHERE id = p_character_id;\n    v_diff := v_diff + v_burden;\n  END IF;\n');
  v_src := replace(v_src, E'    v_grew := public.rpg_trickle(p_character_id, p_stat_key, v_points);\n  END IF;\n',
                          E'    v_grew := public.rpg_trickle(p_character_id, p_stat_key, v_points);\n  END IF;\n  -- a successful Prayer or Bible Study eases the burden and restores the Shield of Faith (rpg_discipline_effects)\n  IF v_discipline AND v_result <> '''' THEN\n    v_disc := public.rpg_discipline_effects(p_character_id, v_roll - (v_nc->>''needed'')::numeric);\n  END IF;\n');
  v_src := replace(v_src, '''grew'', v_grew, ', '''grew'', v_grew, ''discipline'', v_disc, ');
  EXECUTE format('CREATE OR REPLACE FUNCTION public.rpg_roll(p_character_id uuid, p_stat_key text, p_difficulty numeric DEFAULT NULL::numeric, p_label text DEFAULT NULL::text, p_parent_roll_id uuid DEFAULT NULL::uuid, p_session_id uuid DEFAULT NULL::uuid, p_participant_id uuid DEFAULT NULL::uuid, p_roll integer DEFAULT NULL::integer) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS %L', v_src);
END $do$;

-- 8. rpg_act: a discipline in a fight is the turn's action and costs its energy; the Shield of Faith wears (patched by anchors)
DO $do$
DECLARE v_src text; v_n int;
BEGIN
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_act';
  IF v_src LIKE '%rpg_shield_state%' THEN RETURN; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, 'v_damage_ok boolean := false; v_is_attack boolean := false; v_stat_name text; v_spirit_fx boolean := false;', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_act anchor 1 found % times', v_n; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '    ELSE\n      v_kind := ''check''; v_beats := 0; v_ecost := 0;\n      v_diff := greatest\(coalesce\(p_difficulty, public\.rpg_setting\(''default_difficulty''\)\), 0\);\n    END IF;\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_act anchor 2 found % times', v_n; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '  IF v_beats > 0 AND \(v_kind IN \(''attack'', ''action''\) OR v_ending\) THEN\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_act anchor 3 found % times', v_n; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '  IF v_ecost > 0 AND \(v_kind IN \(''attack'', ''action''\) OR v_ending\) THEN\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_act anchor 4 found % times', v_n; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '          v_blk := public\.rpg_participant_value\(v_tid, ''SF''\); v_blocker_name := ''Shield of Faith'';\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_act anchor 5 found % times', v_n; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '              IF v_weapon IS NOT NULL THEN PERFORM public\.rpg_item_damage\(v_weapon, ceil\(v_dmg / 5\.0\)::integer\); END IF;\n            END IF;\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_act anchor 6 found % times', v_n; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '    v_tail := '''';\n    IF p_effect IS NOT NULL THEN\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_act anchor 7 found % times', v_n; END IF;
  v_src := replace(v_src, 'v_damage_ok boolean := false; v_is_attack boolean := false; v_stat_name text; v_spirit_fx boolean := false;',
                          'v_damage_ok boolean := false; v_is_attack boolean := false; v_stat_name text; v_spirit_fx boolean := false; v_discipline boolean := false; v_shield jsonb;');
  v_src := replace(v_src, E'    ELSE\n      v_kind := ''check''; v_beats := 0; v_ecost := 0;\n      v_diff := greatest(coalesce(p_difficulty, public.rpg_setting(''default_difficulty'')), 0);\n    END IF;\n',
                          E'    ELSE\n      v_kind := ''check'';\n      v_diff := greatest(coalesce(p_difficulty, public.rpg_setting(''default_difficulty'')), 0);\n      -- Prayer and Bible Study in a fight: your own turn''s action, paid from spiritual energy (rpg_roll adds the burden to the difficulty)\n      SELECT coalesce(d.spirit_discipline, false) INTO v_discipline FROM public.rpg_stat_definitions d WHERE d.key = p_stat_key;\n      IF v_discipline THEN\n        IF v_s.current_participant_id IS DISTINCT FROM p_actor_id THEN RAISE EXCEPTION ''it is not %''''s turn'', v_actor.name; END IF;\n        IF v_s.turn_action_ticks > 0 THEN RAISE EXCEPTION ''% has already acted this turn'', v_actor.name; END IF;\n        IF (v_energy->v_etype->>''left'')::integer < v_ecost THEN RAISE EXCEPTION ''% has % % energy left and % costs %'', v_actor.name, v_energy->v_etype->>''left'', v_etype, v_stat_name, v_ecost; END IF;\n      ELSE\n        v_beats := 0; v_ecost := 0;\n      END IF;\n    END IF;\n');
  v_src := replace(v_src, E'  IF v_beats > 0 AND (v_kind IN (''attack'', ''action'') OR v_ending) THEN\n',
                          E'  IF v_beats > 0 AND (v_kind IN (''attack'', ''action'') OR v_ending OR v_discipline) THEN\n');
  v_src := replace(v_src, E'  IF v_ecost > 0 AND (v_kind IN (''attack'', ''action'') OR v_ending) THEN\n',
                          E'  IF v_ecost > 0 AND (v_kind IN (''attack'', ''action'') OR v_ending OR v_discipline) THEN\n');
  v_src := replace(v_src, E'          v_blk := public.rpg_participant_value(v_tid, ''SF''); v_blocker_name := ''Shield of Faith'';\n',
                          E'          -- the Shield of Faith blocks while it has life left (3 × its value); broken, it blocks nothing until Prayer or Bible Study restore it\n          v_shield := public.rpg_shield_state(v_t.character_id);\n          IF (v_shield->>''broken'')::boolean THEN v_blk := NULL; ELSE v_blk := public.rpg_participant_value(v_tid, ''SF''); END IF;\n          v_blocker_name := ''Shield of Faith'';\n');
  v_src := replace(v_src, E'              IF v_weapon IS NOT NULL THEN PERFORM public.rpg_item_damage(v_weapon, ceil(v_dmg / 5.0)::integer); END IF;\n            END IF;\n',
                          E'              IF v_weapon IS NOT NULL THEN PERFORM public.rpg_item_damage(v_weapon, ceil(v_dmg / 5.0)::integer); END IF;\n            END IF;\n            IF v_blocker IS NULL AND v_spirit_fx THEN\n              -- the Shield of Faith takes the attack''s strength: the landing die minus what it needed\n              v_wear := public.rpg_shield_wear(v_t.character_id, greatest((v_first->>''roll'')::integer - v_needs, 0));\n              v_tail := v_tail || '' The Shield of Faith takes '' || (v_wear->>''taken'')::numeric::integer || CASE WHEN (v_wear->>''broke'')::boolean THEN '' and breaks.'' ELSE '', '' || (v_wear->>''left'')::numeric::integer || '' left.'' END;\n            END IF;\n');
  v_src := replace(v_src, E'    v_tail := '''';\n    IF p_effect IS NOT NULL THEN\n',
                          E'    v_tail := coalesce('' '' || nullif(v_first->''discipline''->>''text'', ''''), '''');\n    IF p_effect IS NOT NULL THEN\n');
  EXECUTE format('CREATE OR REPLACE FUNCTION public.rpg_act(p_actor_id uuid, p_target_ids uuid[] DEFAULT NULL::uuid[], p_stat_key text DEFAULT NULL::text, p_action_id uuid DEFAULT NULL::uuid, p_against text DEFAULT NULL::text, p_difficulty numeric DEFAULT NULL::numeric, p_roll integer DEFAULT NULL::integer, p_effect text DEFAULT NULL::text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS %L', v_src);
END $do$;

-- 9. rpg_sheet carries the burden and the Shield of Faith's life (patched by anchors)
DO $do$
DECLARE v_src text; v_n int;
BEGIN
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_sheet';
  IF v_src LIKE '%rpg_shield_state%' THEN RETURN; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '    ''items'', v_items, ''stats'', v_stats, ''basics'', v_basics,\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_sheet anchor found % times', v_n; END IF;
  v_src := replace(v_src, E'    ''items'', v_items, ''stats'', v_stats, ''basics'', v_basics,\n',
                          E'    ''spiritual_burden'', coalesce(v_c.spiritual_burden, 0), ''shield'', public.rpg_shield_state(p_character_id),\n    ''items'', v_items, ''stats'', v_stats, ''basics'', v_basics,\n');
  EXECUTE format('CREATE OR REPLACE FUNCTION public.rpg_sheet(p_character_id uuid, p_difficulty numeric DEFAULT NULL::numeric) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS %L', v_src);
END $do$;

-- 10. The rule cards
INSERT INTO public.rpg_rules (agency_id, key, title, body, source, section, sort_order)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'spirit_loop', 'Prayer, Bible Study and the Burden',
E'Prayer and Bible Study are skills on the sheet, rolled like any other and trained by every roll. Prayer is (Connection with God × 2 + Faith + Shield of Faith + Breastplate of Righteousness) ÷ 5, plus Stillness and Trust. Bible Study is (Connection with God × 2 + Knowledge + Belt of Truth + Helmet of Salvation + Boots of the Gospel of Peace) ÷ 6, plus Attention. Their points trickle down like any skill''s (see Basics and Trickle), so praying and studying grow Connection with God and train the armor of God. In a fight either one is the turn''s action and costs 3 spiritual energy.\n*A prayer paying 25 points sends about 3.6 to Connection with God. At Connection with God 5 the next level (11,000 points) takes about 1,500 prayers. A prayer or Bible study at home is an event the game master enters: +1 Connection with God.*\n\nSpiritual burden is the weight of sins and bad decisions, set by the game master from the sheet. In a fight it lowers the Boots of the Gospel of Peace evade by its amount, and it raises the difficulty of Prayer and Bible Study by its amount.\n*Burden 6: Prayer 5 against difficulty 5 needs 50; against 11 it needs 69. Boots of the Gospel of Peace 7 evades as 1.*\n\nA successful Prayer or Bible Study works off (die − Needed) ÷ 10, rounded up and at least 1, and restores the Shield of Faith by die − Needed.\n*A 70 needing 50 works off 2 burden and restores 20 to the Shield of Faith.*',
'peter', 'Getting Better', 67)
ON CONFLICT (agency_id, key) DO NOTHING;

UPDATE public.rpg_rules SET body = body || E'\n\nThe Shield of Faith has a life of 3 × its value (Shield of Faith 6 has 18) and takes the strength of every spiritual attack it stops (the attacker''s die minus what it needed). At 0 it blocks nothing until Prayer or Bible Study restore it.'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'attack_gates' AND body NOT LIKE '%life of 3 × its value%';

UPDATE public.rpg_rules SET body = body || E'\n\nRepair: the game master repairs an item from the sheet, the shop at the table, at 1 silver for every point of life restored, paid from the owner''s coins (a dagger with 30 of 47 life missing costs 30 silver). An owner who cannot pay waits.'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'items' AND body NOT LIKE '%Repair:%';
