-- 20260929015000_roleplaying_unify9a_basics_and_trickle
-- Sheet redesign, step 1 (Peter 2026-09-28, "defaults" = 1A hidden basics, 2A trickle).
-- Hidden basics: trainable stats that start at 0 for everyone (grp 'basic', hidden from the sheet and the Rules list),
-- added whole to every skill built on them through a new formula list "plus": Sword = (CO + EN + SB + AG + ST) ÷ 5,
-- plus Swing arm, Grip and Footwork. The trickle: a roll's points also flow down to what the skill is built from,
-- halving at each layer (setting trickle_share); traits climb through rpg_move_trait, the one home of trait movement,
-- so earned_levels on a rolled stat is retired (no live row carried one). rpg_add_skill_points stays the one writer
-- of rpg_character_skills and now knows the trait branch; rpg_apply_experience uses it for every entry.

-- 1. The setting
INSERT INTO public.rpg_settings (agency_id, key, value, label)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'trickle_share', 0.5,
        'Share of a roll''s points that flows down to what the skill is built from, and again from each part to its own parts')
ON CONFLICT (agency_id, key) DO NOTHING;

-- 2. The basic group
ALTER TABLE public.rpg_stat_definitions DROP CONSTRAINT IF EXISTS rpg_stat_definitions_grp_check;
ALTER TABLE public.rpg_stat_definitions ADD CONSTRAINT rpg_stat_definitions_grp_check
  CHECK (grp = ANY (ARRAY['strength','mind','physical','derived','spiritual','ability','fighting','basic']));

-- 3. The basics: nine on Creature (every living card), Rake on the Bramblemaw alone
INSERT INTO public.rpg_stat_definitions
  (agency_id, key, name, abbr, grp, kind, trainable, formula, default_value, sort_order, is_attack, beats, energy_cost, energy_type, template_id)
SELECT '126794dd-25ff-47d2-a436-724499733365', v.key, v.name, v.abbr, 'basic', 'derived', true, '{"div": 1, "parts": []}'::jsonb, 0,
       v.sort_order, false, 2, 4, 'physical', c.id
  FROM (VALUES
    ('swing_arm', 'Swing arm', 'SWA', 900, 'creature'),
    ('grip',      'Grip',      'GRP', 901, 'creature'),
    ('aim',       'Aim',       'AIM', 902, 'creature'),
    ('footwork',  'Footwork',  'FTW', 903, 'creature'),
    ('brace',     'Brace',     'BRC', 904, 'creature'),
    ('breath',    'Breath',    'BRE', 905, 'creature'),
    ('stillness', 'Stillness', 'STL', 906, 'creature'),
    ('attention', 'Attention', 'ATN', 907, 'creature'),
    ('trust',     'Trust',     'TRU', 908, 'creature'),
    ('rake',      'Rake',      'RKE', 910, 'bramblemaw')) AS v(key, name, abbr, sort_order, card)
  JOIN public.rpg_creatures c ON c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.key = v.card
ON CONFLICT (agency_id, key) DO NOTHING;

-- 4. Which skills are built on which basics (added whole, on top of the average)
UPDATE public.rpg_stat_definitions d
   SET formula = d.formula || jsonb_build_object('plus', v.plus)
  FROM (VALUES
    ('sword',             '[["swing_arm",1],["grip",1],["footwork",1]]'::jsonb),
    ('dagger',            '[["swing_arm",1],["grip",1],["footwork",1]]'),
    ('hand_axe',          '[["swing_arm",1],["grip",1],["footwork",1]]'),
    ('flail',             '[["swing_arm",1],["grip",1],["footwork",1]]'),
    ('battle_axe',        '[["swing_arm",1],["grip",1],["brace",1],["footwork",1]]'),
    ('war_hammer',        '[["swing_arm",1],["grip",1],["brace",1],["footwork",1]]'),
    ('quarterstaff',      '[["swing_arm",1],["grip",1],["brace",1],["footwork",1]]'),
    ('spear',             '[["grip",1],["aim",1],["footwork",1]]'),
    ('lance',             '[["grip",1],["aim",1],["brace",1],["footwork",1]]'),
    ('military_fork',     '[["grip",1],["aim",1],["brace",1],["footwork",1]]'),
    ('crossbow',          '[["grip",1],["aim",1],["breath",1]]'),
    ('longbow',           '[["grip",1],["aim",1],["breath",1]]'),
    ('sling',             '[["grip",1],["aim",1],["breath",1]]'),
    ('hurling',           '[["swing_arm",1],["aim",1]]'),
    ('tossing',           '[["swing_arm",1],["aim",1]]'),
    ('hand_to_hand',      '[["swing_arm",1],["brace",1],["footwork",1]]'),
    ('BLK',               '[["grip",1],["brace",1]]'),
    ('EE',                '[["footwork",1]]'),
    ('QM',                '[["footwork",1],["breath",1]]'),
    ('EN',                '[["breath",1]]'),
    ('healing_physical',  '[["attention",1]]'),
    ('healing_spiritual', '[["stillness",1],["trust",1]]'),
    ('SF',                '[["stillness",1],["trust",1]]'),
    ('BGP',               '[["stillness",1]]'),
    ('BT',                '[["attention",1]]'),
    ('HS',                '[["attention",1]]'),
    ('BR',                '[["trust",1]]'),
    ('CO',                '[["trust",1]]'),
    ('LIS',               '[["attention",1]]'),
    ('claw',              '[["rake",1]]')) AS v(key, plus)
 WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND d.key = v.key AND d.formula IS NOT NULL;

-- 5. Formula text: the "plus" list reads ", plus Swing arm + Grip + Footwork"
CREATE OR REPLACE FUNCTION public.rpg_formula_text(p_formula jsonb, p_names jsonb)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  WITH parts AS (
    SELECT string_agg(CASE WHEN (e->>1)::numeric <> 1 THEN (e->>1) || ' × ' ELSE '' END || coalesce(p_names->>(e->>0), e->>0), ' + ' ORDER BY ord) AS txt
      FROM jsonb_array_elements(coalesce(p_formula->'parts', '[]'::jsonb)) WITH ORDINALITY AS t(e, ord)),
  plus AS (
    SELECT string_agg(CASE WHEN (e->>1)::numeric <> 1 THEN (e->>1) || ' × ' ELSE '' END || coalesce(p_names->>(e->>0), e->>0), ' + ' ORDER BY ord) AS txt
      FROM jsonb_array_elements(coalesce(p_formula->'plus', '[]'::jsonb)) WITH ORDINALITY AS t(e, ord))
  SELECT CASE WHEN p_formula IS NULL THEN NULL ELSE
    concat_ws(', plus ',
      CASE WHEN parts.txt IS NULL THEN NULL
           WHEN coalesce((p_formula->>'div')::numeric, 1) > 1 THEN '(' || parts.txt || ') ÷ ' || (p_formula->>'div') || ', rounded down'
           ELSE parts.txt END,
      plus.txt) END
  FROM parts, plus;
$fn$;

-- 6. The numbers on a sheet: the "plus" list is added whole; a rolled number carries its own levels (rpg_move_trait)
CREATE OR REPLACE FUNCTION public.rpg_sheet_values(p_character_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
-- The numbers on one character's sheet and nothing else, figured from its card (rpg_template_stat_defs), its rolls,
-- its items and its earned levels: {values {key: value}, raw {key: value before the Spirit pairs net out}, bonus,
-- earned, points, side, vitality_max, vitality_damage}. rpg_sheet shows these; the fight functions read them, so a
-- fighter's numbers are figured one way everywhere. A creature made from a card is a character like any other.
-- A rolled or fixed stat is its rolled number plus items; the levels a trait earns from play or a card move the rolled
-- number itself (rpg_move_trait), never earned_levels. A calculated stat is its parts averaged, rounded down, plus
-- each stat in its "plus" list taken whole (the hidden basics: Swing arm 2 adds 2 to Sword), plus items and levels.
-- Karen: values.EE 4, vitality_max 41. A Bramblemaw: values.EE 8, values.claw 10, values.IG 8, vitality_max 149.
-- Internal: revoked from logins; callers check who is asking.
DECLARE
  v_c       record;
  v_defs    public.rpg_stat_definitions[];
  v_d       public.rpg_stat_definitions;
  v_vals    jsonb := '{}'::jsonb;
  v_bonus   jsonb;
  v_earned  jsonb;
  v_points  jsonb;
  v_pass    integer := 0;
  v_moved   boolean;
  v_part    jsonb;
  v_total   numeric;
  v_plus    numeric;
  v_ok      boolean;
  v_div     numeric;
  v_v       numeric;
  v_raw     jsonb;
  v_good    numeric;
  v_evil    numeric;
  v_side    text := 'good';
BEGIN
  SELECT * INTO v_c FROM public.rpg_characters WHERE id = p_character_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'character not found'; END IF;
  v_defs := ARRAY(SELECT d FROM public.rpg_template_stat_defs(v_c.template_id) d ORDER BY d.sort_order, d.key);

  SELECT coalesce(jsonb_object_agg(x.stat_key, x.b), '{}'::jsonb) INTO v_bonus
  FROM (SELECT i.stat_key, sum(i.bonus) AS b FROM public.rpg_items i
        WHERE i.character_id = p_character_id AND i.equipped AND i.stat_key IS NOT NULL
          AND (i.uses_left IS NULL OR i.uses_left > 0)
        GROUP BY i.stat_key) x;
  SELECT coalesce(jsonb_object_agg(s.stat_key, s.earned_levels), '{}'::jsonb),
         coalesce(jsonb_object_agg(s.stat_key, s.skill_points), '{}'::jsonb)
    INTO v_earned, v_points
  FROM public.rpg_character_skills s WHERE s.character_id = p_character_id;

  -- rolled and fixed stats come straight from the character
  FOREACH v_d IN ARRAY v_defs LOOP
    CONTINUE WHEN v_d.kind NOT IN ('rolled','fixed');
    v_v := coalesce((v_c.inputs->>v_d.key)::numeric, v_d.default_value) + coalesce((v_bonus->>v_d.key)::numeric, 0);
    v_vals := v_vals || jsonb_build_object(v_d.key, v_v);
  END LOOP;

  -- paired Spirit traits: the net (winner minus loser) sits on the good side and feeds every formula; the label is the
  -- winner's. The evil side reads how far it wins, 0 when it loses (the Bramblemaw's Fascination with Evil 12).
  -- The root pair (Connection with God / Fascination with Evil) says which side the being is on.
  v_raw := v_vals;
  FOREACH v_d IN ARRAY v_defs LOOP
    CONTINUE WHEN v_d.side IS DISTINCT FROM 'good' OR v_d.pair_key IS NULL;
    v_good := coalesce((v_raw->>v_d.key)::numeric, 0); v_evil := coalesce((v_raw->>v_d.pair_key)::numeric, 0);
    v_vals := v_vals || jsonb_build_object(v_d.key, abs(v_good - v_evil), v_d.pair_key, greatest(v_evil - v_good, 0));
    IF v_d.key = 'CG' AND v_evil > v_good THEN v_side := 'evil'; END IF;
  END LOOP;

  -- derived stats, resolved in dependency order (a stat waits until every part it uses is known)
  LOOP
    v_pass := v_pass + 1; v_moved := false;
    FOREACH v_d IN ARRAY v_defs LOOP
      CONTINUE WHEN v_d.kind <> 'derived' OR v_vals ? v_d.key;
      v_ok := true; v_total := 0; v_plus := 0;
      FOR v_part IN SELECT e FROM jsonb_array_elements(coalesce(v_d.formula->'parts', '[]'::jsonb)) e LOOP
        IF NOT (v_vals ? (v_part->>0)) THEN v_ok := false; EXIT; END IF;
        v_total := v_total + (v_vals->>(v_part->>0))::numeric * (v_part->>1)::numeric;
      END LOOP;
      IF v_ok THEN
        FOR v_part IN SELECT e FROM jsonb_array_elements(coalesce(v_d.formula->'plus', '[]'::jsonb)) e LOOP
          IF NOT (v_vals ? (v_part->>0)) THEN v_ok := false; EXIT; END IF;
          v_plus := v_plus + (v_vals->>(v_part->>0))::numeric * (v_part->>1)::numeric;
        END LOOP;
      END IF;
      CONTINUE WHEN NOT v_ok;
      v_div := coalesce((v_d.formula->>'div')::numeric, 1);
      v_v := floor(v_total / v_div) + v_plus
           + coalesce((v_bonus->>v_d.key)::numeric, 0) + coalesce((v_earned->>v_d.key)::numeric, 0);
      v_vals := v_vals || jsonb_build_object(v_d.key, v_v);
      v_moved := true;
    END LOOP;
    EXIT WHEN NOT v_moved OR v_pass >= 12;
  END LOOP;

  RETURN jsonb_build_object('values', v_vals, 'raw', v_raw, 'bonus', v_bonus, 'earned', v_earned, 'points', v_points,
                            'side', v_side, 'vitality_max', coalesce((v_vals->>'PV')::numeric, 0),
                            'vitality_damage', v_c.vitality_damage);
END;
$fn$;

-- 7. The one writer of banked points, now with the trait branch
CREATE OR REPLACE FUNCTION public.rpg_add_skill_points(p_character_id uuid, p_stat_key text, p_points numeric, p_value_now numeric)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
-- Adds points to one of a character's stats and turns them into levels with rpg_climb_levels; leftover points wait in
-- rpg_character_skills for the next level. Returns the value after. The ONE writer of rpg_character_skills.
-- A skill or a basic (a calculated, trainable stat) climbs from p_value_now, its sheet value, and keeps its levels in
-- earned_levels: Karen's Sword 6 with 13,000 points becomes 7.
-- A trait (a rolled or fixed stat: Strength, Focus, Love) climbs from its own rolled number, ignoring p_value_now, and
-- its levels go through rpg_move_trait (not strict), the one home of trait movement and the Spirit pair rules, so the
-- rolled number itself moves and earned_levels stays 0: Strength 10 with 21,000 points becomes 11; Love already at its
-- root's cap stays there and the points are spent. Used by rpg_roll (a roll's points), rpg_trickle (what flows down)
-- and rpg_apply_experience (a card's growth), so every climb takes the same ladder.
DECLARE
  v_d      record;
  v_sp     numeric;
  v_earned integer;
  v_now    integer;
  v_level  integer;
  v_left   numeric;
  v_moved  numeric := 0;
BEGIN
  SELECT d.kind, d.default_value INTO v_d FROM public.rpg_stat_definitions d
   WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND d.key = p_stat_key;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown stat %', p_stat_key; END IF;
  IF v_d.kind IN ('rolled', 'fixed') THEN
    SELECT coalesce((c.inputs ->> p_stat_key)::numeric, v_d.default_value, 0)::integer INTO v_now
      FROM public.rpg_characters c WHERE c.id = p_character_id;
  ELSE
    v_now := coalesce(p_value_now, 0)::integer;
  END IF;
  INSERT INTO public.rpg_character_skills (character_id, stat_key) VALUES (p_character_id, p_stat_key)
    ON CONFLICT (character_id, stat_key) DO NOTHING;
  SELECT skill_points, earned_levels INTO v_sp, v_earned
    FROM public.rpg_character_skills WHERE character_id = p_character_id AND stat_key = p_stat_key FOR UPDATE;
  SELECT c.level, c.leftover INTO v_level, v_left FROM public.rpg_climb_levels(v_now, v_sp + coalesce(p_points, 0)) c;
  IF v_d.kind IN ('rolled', 'fixed') THEN
    IF v_level > v_now THEN
      v_moved := public.rpg_move_trait(p_character_id, p_stat_key, v_level - v_now, false);
    END IF;
    UPDATE public.rpg_character_skills SET skill_points = v_left
     WHERE character_id = p_character_id AND stat_key = p_stat_key;
    RETURN v_now + v_moved;
  END IF;
  UPDATE public.rpg_character_skills SET skill_points = v_left, earned_levels = v_earned + (v_level - v_now)
   WHERE character_id = p_character_id AND stat_key = p_stat_key;
  RETURN v_level;
END;
$fn$;

-- 8. The trickle
CREATE OR REPLACE FUNCTION public.rpg_trickle(p_character_id uuid, p_stat_key text, p_points numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
-- The trickle: what a roll pays a skill also flows down to what the skill is built from. Of the roll's points, the
-- trickle_share setting (0.5) is split by weight among every part in the skill's formula (the averaged parts and the
-- basics in its "plus" list, a basic counting weight 1), and each part passes the same share of what it got on down to
-- its own parts, until a stat has no parts or a share is under 0.01 point. A skill, a basic or a trait banks its share
-- through rpg_add_skill_points (a trait climbs through rpg_move_trait when its bank covers the next level); a
-- calculated stat that is not trainable (an armor piece) banks nothing but still passes its share down.
-- Karen's Sword swing paying 27.3 points: 13.6 flows down, 1.7 each to Courage, Endurance, Solo Battle, Agility,
-- Strength, Swing arm, Grip and Footwork; Courage passes 0.85 on, split six ways among the strengths it is built from.
-- Returns {stat: value after} for every stat that climbed. Called by rpg_roll after the roll's own points.
-- Internal: revoked from logins.
DECLARE
  v_c      record;
  v_share  numeric := coalesce(public.rpg_setting('trickle_share'), 0.5);
  v_defs   jsonb;
  v_vals   jsonb;
  v_grew   jsonb := '{}'::jsonb;
  v_queue  jsonb;
  v_head   jsonb;
  v_key    text;
  v_amt    numeric;
  v_parts  jsonb;
  v_sumw   numeric;
  v_e      jsonb;
  v_k      text;
  v_s      numeric;
  v_kind   text;
  v_before numeric;
  v_after  numeric;
  v_n      integer := 0;
BEGIN
  IF coalesce(p_points, 0) <= 0 OR v_share <= 0 THEN RETURN v_grew; END IF;
  SELECT * INTO v_c FROM public.rpg_characters WHERE id = p_character_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'character not found'; END IF;
  SELECT coalesce(jsonb_object_agg(d.key, jsonb_build_object('kind', d.kind, 'trainable', d.trainable, 'formula', d.formula)), '{}'::jsonb)
    INTO v_defs FROM public.rpg_template_stat_defs(v_c.template_id) d;
  v_vals := public.rpg_sheet_values(p_character_id) -> 'values';
  v_queue := jsonb_build_array(jsonb_build_array(p_stat_key, p_points * v_share));
  WHILE jsonb_array_length(v_queue) > 0 AND v_n < 500 LOOP
    v_n := v_n + 1;
    v_head := v_queue -> 0; v_queue := v_queue - 0;
    v_key := v_head ->> 0; v_amt := (v_head ->> 1)::numeric;
    CONTINUE WHEN v_amt < 0.01 OR NOT (v_defs ? v_key);
    v_parts := coalesce(v_defs -> v_key -> 'formula' -> 'parts', '[]'::jsonb) || coalesce(v_defs -> v_key -> 'formula' -> 'plus', '[]'::jsonb);
    CONTINUE WHEN jsonb_array_length(v_parts) = 0;
    SELECT sum((e ->> 1)::numeric) INTO v_sumw FROM jsonb_array_elements(v_parts) e;
    CONTINUE WHEN coalesce(v_sumw, 0) <= 0;
    FOR v_e IN SELECT e FROM jsonb_array_elements(v_parts) e LOOP
      v_k := v_e ->> 0;
      v_s := v_amt * (v_e ->> 1)::numeric / v_sumw;
      CONTINUE WHEN v_s < 0.01 OR NOT (v_defs ? v_k);
      v_kind := v_defs -> v_k ->> 'kind';
      IF v_kind IN ('rolled', 'fixed') THEN
        SELECT coalesce((c.inputs ->> v_k)::numeric, 0) INTO v_before FROM public.rpg_characters c WHERE c.id = p_character_id;
        v_after := public.rpg_add_skill_points(p_character_id, v_k, v_s, v_before);
        IF v_after > v_before THEN v_grew := v_grew || jsonb_build_object(v_k, v_after); END IF;
      ELSIF coalesce((v_defs -> v_k ->> 'trainable')::boolean, false) THEN
        v_before := coalesce((v_vals ->> v_k)::numeric, 0);
        v_after := public.rpg_add_skill_points(p_character_id, v_k, v_s, v_before);
        IF v_after > v_before THEN
          v_grew := v_grew || jsonb_build_object(v_k, v_after);
          v_vals := v_vals || jsonb_build_object(v_k, v_after);
        END IF;
      END IF;
      v_queue := v_queue || jsonb_build_array(jsonb_build_array(v_k, v_s * v_share));
    END LOOP;
  END LOOP;
  RETURN v_grew;
END;
$fn$;
REVOKE ALL ON FUNCTION public.rpg_trickle(uuid, text, numeric) FROM PUBLIC, anon, authenticated;

-- 9. A card's experience through the one writer
CREATE OR REPLACE FUNCTION public.rpg_apply_experience(p_character_id uuid, p_card uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
-- For every entry with "points" in the card's blueprint (its own and its parents'), in sheet order (the root pair,
-- then the fruits, then Mind and Body, then skills, so each sees the final numbers of what it is built on): the stat
-- starts over (a reroll makes the character again) and spends the points from where it stands through
-- rpg_add_skill_points, the one writer of banked points. A trait climbs from its rolled number and moves through
-- rpg_move_trait: a Gloam Wisp's Hatred 4 with 80,000 points climbs to 9, unless its Fascination with Evil is lower,
-- in which case it stops there. A skill climbs from its value on the fresh sheet.
-- Used by rpg_new_character and rpg_reroll_character.
DECLARE
  v_key text;
  v_pts numeric;
  v_now numeric;
BEGIN
  FOR v_key, v_pts IN
    SELECT b.key, (b.value ->> 'points')::numeric
      FROM jsonb_each(public.rpg_template_blueprint(p_card)) b
      LEFT JOIN public.rpg_stat_definitions d ON d.key = b.key AND d.agency_id = '126794dd-25ff-47d2-a436-724499733365'
     WHERE jsonb_typeof(b.value) = 'object' AND jsonb_typeof(b.value -> 'points') = 'number'
     ORDER BY d.sort_order NULLS LAST, b.key
  LOOP
    DELETE FROM public.rpg_character_skills WHERE character_id = p_character_id AND stat_key = v_key;
    v_now := (public.rpg_sheet_values(p_character_id) -> 'values' ->> v_key)::numeric;
    PERFORM public.rpg_add_skill_points(p_character_id, v_key, v_pts, coalesce(v_now, 0));
  END LOOP;
END;
$fn$;

-- 10. A reroll starts every rolled number over, banked points included
CREATE OR REPLACE FUNCTION public.rpg_reroll_character(p_character_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
-- The character made again from its own card: a Human rolls every trait again; a card's set numbers come back the
-- same; a card's experience is spent again from the new roll. The points a trait had banked toward its next level go
-- with the old roll; skills keep their levels and banks. A player may re-roll only a character that has not played yet.
DECLARE
  v_card uuid;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rpg_characters WHERE id = p_character_id) OR NOT public.rpg_can_see_character(p_character_id) THEN
    RAISE EXCEPTION 'character not found';
  END IF;
  IF NOT public.family_is_parent() AND EXISTS (SELECT 1 FROM public.rpg_rolls WHERE character_id = p_character_id) THEN
    RAISE EXCEPTION 'this character has already played; ask a parent to re-roll';
  END IF;
  DELETE FROM public.rpg_character_skills s
   USING public.rpg_stat_definitions d
   WHERE s.character_id = p_character_id AND d.key = s.stat_key
     AND d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND d.kind IN ('rolled', 'fixed');
  UPDATE public.rpg_characters SET inputs = public.rpg_roll_inputs(template_id) WHERE id = p_character_id
  RETURNING template_id INTO v_card;
  PERFORM public.rpg_apply_experience(p_character_id, v_card);
  RETURN public.rpg_sheet(p_character_id);
END;
$fn$;

-- 11. rpg_roll: the roll's own points, then the trickle (patched on the live body by anchors)
DO $do$
DECLARE v_src text; v_n int;
BEGIN
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rpg_roll';
  IF v_src LIKE '%rpg_trickle%' THEN RETURN; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, 'v_points numeric := 0; v_before integer; v_after integer;', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_roll anchor 1 found % times', v_n; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '    v_after := public\.rpg_add_skill_points\(p_character_id, p_stat_key, v_points, v_before\);\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_roll anchor 2 found % times', v_n; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '''level_before'', v_before, ''level_after'', v_after, ', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_roll anchor 3 found % times', v_n; END IF;
  v_src := replace(v_src, 'v_points numeric := 0; v_before integer; v_after integer;',
                          'v_points numeric := 0; v_before integer; v_after integer; v_grew jsonb := ''{}''::jsonb;');
  v_src := replace(v_src, E'    v_after := public.rpg_add_skill_points(p_character_id, p_stat_key, v_points, v_before);\n',
                          E'    v_after := public.rpg_add_skill_points(p_character_id, p_stat_key, v_points, v_before);\n    v_grew := public.rpg_trickle(p_character_id, p_stat_key, v_points);\n');
  v_src := replace(v_src, '''level_before'', v_before, ''level_after'', v_after, ',
                          '''level_before'', v_before, ''level_after'', v_after, ''grew'', v_grew, ');
  v_src := replace(v_src, E'-- random one. Needed comes from rpg_needed; an opponent''s difficulty arrives already derived by rpg_difficulty.\n',
                          E'-- random one. Needed comes from rpg_needed; an opponent''s difficulty arrives already derived by rpg_difficulty.\n-- After the roll''s own points, rpg_trickle sends half as much down to what the skill is built from; ''grew'' lists\n-- every stat that climbed a level from that (Karen''s Footwork reaching 1, her Sword reading 7).\n');
  EXECUTE format('CREATE OR REPLACE FUNCTION public.rpg_roll(p_character_id uuid, p_stat_key text, p_difficulty numeric DEFAULT NULL::numeric, p_label text DEFAULT NULL::text, p_parent_roll_id uuid DEFAULT NULL::uuid, p_session_id uuid DEFAULT NULL::uuid, p_participant_id uuid DEFAULT NULL::uuid, p_roll integer DEFAULT NULL::integer) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS %L', v_src);
END $do$;

-- 12. rpg_sheet: basics hidden from the stats and listed on their own (patched on the live body by anchors)
DO $do$
DECLARE v_src text; v_n int;
BEGIN
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rpg_sheet';
  IF v_src LIKE '%''basics''%' THEN RETURN; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '    CONTINUE WHEN v_d\.side = ''evil'';\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_sheet anchor 1 found % times', v_n; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '  v_evil    numeric;\nBEGIN', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_sheet anchor 2 found % times', v_n; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '  SELECT k\.name INTO v_kid FROM public\.family_kids k WHERE k\.id = v_c\.kid_id;\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_sheet anchor 3 found % times', v_n; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '    ''items'', v_items, ''stats'', v_stats\);', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_sheet anchor 4 found % times', v_n; END IF;
  v_src := replace(v_src, E'    CONTINUE WHEN v_d.side = ''evil'';\n',
                          E'    CONTINUE WHEN v_d.side = ''evil'' OR v_d.grp = ''basic'';\n');
  v_src := replace(v_src, E'  v_evil    numeric;\nBEGIN',
                          E'  v_evil    numeric;\n  v_basics  jsonb := ''[]''::jsonb;\nBEGIN');
  v_src := replace(v_src, E'  SELECT k.name INTO v_kid FROM public.family_kids k WHERE k.id = v_c.kid_id;\n',
                          E'  -- the hidden basics (Swing arm, Grip, ...): not stats on the sheet, shown inside the skills built on them\n  FOREACH v_d IN ARRAY v_defs LOOP\n    CONTINUE WHEN v_d.grp <> ''basic'';\n    v_v := coalesce((v_vals->>v_d.key)::numeric, 0);\n    v_basics := v_basics || jsonb_build_object(''key'', v_d.key, ''name'', v_d.name, ''abbr'', v_d.abbr, ''value'', v_v,\n      ''skill_points'', round(coalesce((v_points->>v_d.key)::numeric, 0), 1), ''next_level_cost'', public.rpg_level_cost(v_v::integer));\n  END LOOP;\n\n  SELECT k.name INTO v_kid FROM public.family_kids k WHERE k.id = v_c.kid_id;\n');
  v_src := replace(v_src, '    ''items'', v_items, ''stats'', v_stats);',
                          '    ''items'', v_items, ''stats'', v_stats, ''basics'', v_basics);');
  EXECUTE format('CREATE OR REPLACE FUNCTION public.rpg_sheet(p_character_id uuid, p_difficulty numeric DEFAULT NULL::numeric) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS %L', v_src);
END $do$;

-- 13. Rules tab: basics are hidden there too (patched on the live body by anchors)
DO $do$
DECLARE v_src text; v_n int;
BEGIN
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rpg_rules_page';
  IF v_src LIKE '%''basic''%' THEN RETURN; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '              WHERE d\.agency_id = ''126794dd-25ff-47d2-a436-724499733365''\n                AND \(d\.template_id IS NULL', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_rules_page anchor found % times', v_n; END IF;
  v_src := replace(v_src, E'              WHERE d.agency_id = ''126794dd-25ff-47d2-a436-724499733365''\n                AND (d.template_id IS NULL',
                          E'              WHERE d.agency_id = ''126794dd-25ff-47d2-a436-724499733365'' AND d.grp <> ''basic''\n                AND (d.template_id IS NULL');
  EXECUTE format('CREATE OR REPLACE FUNCTION public.rpg_rules_page(p_max_level integer DEFAULT 30) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS %L', v_src);
END $do$;

-- 14. The rule cards
UPDATE public.rpg_rules
   SET body = replace(body,
       'Abilities, strengths, and attributes can only be increased through special means.',
       'Strengths and traits grow too: a trickle from every skill that uses them (see Basics and Trickle), and events the game master enters.')
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'skill_gain'
   AND body LIKE '%Abilities, strengths, and attributes can only be increased through special means.%';

INSERT INTO public.rpg_rules (agency_id, key, title, body, source, section, sort_order)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'basics', 'Basics and Trickle',
E'Every weapon and spiritual skill is built on a few basics that never show on the sheet: Swing arm, Grip, Aim, Footwork, Brace and Breath for the body; Stillness, Attention and Trust for the spirit. Everyone starts with every basic at 0. A basic climbs the same level ladder as a skill (0 to 1 costs 1,000 points, 1 to 2 costs 3,000), and each level it gains adds one whole point to every skill built on it.\n*Sword is (Courage + Endurance + Solo Battle + Agility + Strength) ÷ 5, rounded down, plus Swing arm, Grip and Footwork. Karen''s Sword 6 becomes 7 the day her Footwork reaches 1, and so does her Dagger.*\n\nPoints trickle down. When a roll pays a skill, half as much flows down to what the skill is built from, split by weight, and each part passes half of its share on down to its own parts. A basic or a trainable skill banks what reaches it. A trait (Strength, Focus, Love) banks it too and climbs one whole level when the bank covers the ladder, with the Spirit pair rules as always.\n*Karen rolls a 60 with her Sword against difficulty 5 (Needed 45): the Sword gets 27 points and 13.6 flows down, 1.7 each to Courage, Endurance, Solo Battle, Agility, Strength, Swing arm, Grip and Footwork. Courage passes 0.85 on to the strengths it is built from. After about 600 swings her Swing arm reaches 1. Strength 10 to 11 costs 21,000 points, about 12,000 swings.*',
'peter', 'Getting Better', 65)
ON CONFLICT (agency_id, key) DO NOTHING;
