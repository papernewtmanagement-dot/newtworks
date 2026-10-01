-- Roleplaying skill tree step 1 (Peter 2026-10-01 Defaults = 1A 2A 3B): basics add their average (3B); rpg_skill_tree.
CREATE OR REPLACE FUNCTION public.rpg_sheet_values(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The numbers on one character's sheet and nothing else, figured from its card (rpg_template_stat_defs), its rolls,
-- its items and its earned levels: {values {key: value}, raw {key: value before the Spirit pairs net out}, bonus,
-- earned, points, side, vitality_max, vitality_damage}. rpg_sheet shows these; the fight functions read them, so a
-- fighter's numbers are figured one way everywhere. A creature made from a card is a character like any other.
-- A rolled or fixed stat is its rolled number plus items; the levels a trait earns from play or a card move the rolled
-- number itself (rpg_move_trait), never earned_levels. A calculated stat is its parts averaged, rounded down, plus
-- the average of its "plus" list, rounded down (the hidden basics: Swing arm 3, Grip 2, Footwork 2 add 2 to Sword),
-- plus items and levels.
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
  v_pw      numeric;
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
          AND NOT coalesce((public.rpg_object_state(i.object_id) ->> 'broken')::boolean, false)
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
      v_ok := true; v_total := 0; v_plus := 0; v_pw := 0;
      FOR v_part IN SELECT e FROM jsonb_array_elements(coalesce(v_d.formula->'parts', '[]'::jsonb)) e LOOP
        IF NOT (v_vals ? (v_part->>0)) THEN v_ok := false; EXIT; END IF;
        v_total := v_total + (v_vals->>(v_part->>0))::numeric * (v_part->>1)::numeric;
      END LOOP;
      IF v_ok THEN
        FOR v_part IN SELECT e FROM jsonb_array_elements(coalesce(v_d.formula->'plus', '[]'::jsonb)) e LOOP
          IF NOT (v_vals ? (v_part->>0)) THEN v_ok := false; EXIT; END IF;
          v_plus := v_plus + (v_vals->>(v_part->>0))::numeric * (v_part->>1)::numeric;
          v_pw := v_pw + (v_part->>1)::numeric;
        END LOOP;
      END IF;
      CONTINUE WHEN NOT v_ok;
      v_div := coalesce((v_d.formula->>'div')::numeric, 1);
      v_v := floor(v_total / v_div) + CASE WHEN v_pw > 0 THEN floor(v_plus / v_pw) ELSE 0 END
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
$function$;

CREATE OR REPLACE FUNCTION public.rpg_formula_text(p_formula jsonb, p_names jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  WITH parts AS (
    SELECT string_agg(CASE WHEN (e->>1)::numeric <> 1 THEN (e->>1) || ' × ' ELSE '' END || coalesce(p_names->>(e->>0), e->>0), ' + ' ORDER BY ord) AS txt
      FROM jsonb_array_elements(coalesce(p_formula->'parts', '[]'::jsonb)) WITH ORDINALITY AS t(e, ord)),
  plus0 AS (
    SELECT string_agg(CASE WHEN (e->>1)::numeric <> 1 THEN (e->>1) || ' × ' ELSE '' END || coalesce(p_names->>(e->>0), e->>0), ', ' ORDER BY ord) AS txt,
           count(*) AS n
      FROM jsonb_array_elements(coalesce(p_formula->'plus', '[]'::jsonb)) WITH ORDINALITY AS t(e, ord)),
  -- the basics under a skill add their average, rounded down: "plus the average of Swing arm, Grip and Footwork, rounded down"
  plus AS (
    SELECT CASE WHEN n > 1 THEN 'the average of ' || regexp_replace(txt, ', ([^,]*)$', ' and \1') || ', rounded down' ELSE txt END AS txt
      FROM plus0)
  SELECT CASE WHEN p_formula IS NULL THEN NULL ELSE
    concat_ws(', plus ',
      CASE WHEN parts.txt IS NULL THEN NULL
           WHEN coalesce((p_formula->>'div')::numeric, 1) > 1 THEN '(' || parts.txt || ') ÷ ' || (p_formula->>'div') || ', rounded down'
           ELSE parts.txt END,
      plus.txt) END
  FROM parts, plus;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_sheet_mix(p_card uuid, p_vals jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The mix line: how much of each stat's number is Spirit, Mind and Body. A rolled or fixed stat is all one side (the
-- nine fruits, the root pair and the Sword of the Spirit are Spirit; Intelligence, Focus, Memory, Perception Mind;
-- Strength, Agility, Toughness Body). A calculated stat takes the mix of what it is built from, each part weighted by
-- what it actually contributes (a part's number × its weight ÷ the divisor; the "plus" basics share one average, so
-- each counts its number × its weight ÷ the plus weights), so a basic still at 0 adds
-- nothing to the line and a trained one pulls it its way. A basic has no parts, so its side is its energy type
-- (Swing arm physical → Body, Stillness spiritual → Spirit). When every part is 0 the weights alone decide.
-- Karen's Sword: Spirit 47, Mind 11, Body 41. Returns {key: {spirit, mind, body}}, whole percents adding to 100,
-- for every stat the card gives. p_vals is rpg_sheet_values(character)->'values'. Used by rpg_sheet. Internal.
DECLARE
  v_defs  public.rpg_stat_definitions[];
  v_d     public.rpg_stat_definitions;
  v_frac  jsonb := '{}'::jsonb;
  v_pass  integer := 0;
  v_moved boolean;
  v_part  jsonb;
  v_ok    boolean;
  v_s     numeric; v_m numeric; v_b numeric; v_tot numeric; v_c numeric;
  v_pm    jsonb;
  v_out   jsonb := '{}'::jsonb;
  v_ps    integer; v_pmi integer; v_pb integer;
  v_e     record;
  v_list  jsonb;
  v_div   numeric;
  v_pw    numeric;
BEGIN
  v_defs := ARRAY(SELECT d FROM public.rpg_template_stat_defs(p_card) d ORDER BY d.sort_order, d.key);
  FOREACH v_d IN ARRAY v_defs LOOP
    IF v_d.kind IN ('rolled', 'fixed') THEN
      v_frac := v_frac || jsonb_build_object(v_d.key, CASE v_d.grp WHEN 'mind' THEN '[0,1,0]'::jsonb WHEN 'physical' THEN '[0,0,1]'::jsonb ELSE '[1,0,0]'::jsonb END);
    ELSIF jsonb_array_length(coalesce(v_d.formula -> 'parts', '[]'::jsonb)) + jsonb_array_length(coalesce(v_d.formula -> 'plus', '[]'::jsonb)) = 0 THEN
      v_frac := v_frac || jsonb_build_object(v_d.key, CASE WHEN v_d.energy_type = 'spiritual' THEN '[1,0,0]'::jsonb ELSE '[0,0,1]'::jsonb END);
    END IF;
  END LOOP;
  LOOP
    v_pass := v_pass + 1; v_moved := false;
    FOREACH v_d IN ARRAY v_defs LOOP
      CONTINUE WHEN v_d.kind <> 'derived' OR v_frac ? v_d.key;
      v_ok := true; v_s := 0; v_m := 0; v_b := 0; v_tot := 0;
      v_div := coalesce((v_d.formula ->> 'div')::numeric, 1);
      SELECT coalesce(sum((e ->> 1)::numeric), 0) INTO v_pw FROM jsonb_array_elements(coalesce(v_d.formula -> 'plus', '[]'::jsonb)) e;
      SELECT coalesce((SELECT jsonb_agg(jsonb_build_array(e ->> 0, (e ->> 1)::numeric / v_div)) FROM jsonb_array_elements(coalesce(v_d.formula -> 'parts', '[]'::jsonb)) e), '[]'::jsonb)
          || coalesce((SELECT jsonb_agg(jsonb_build_array(e ->> 0, (e ->> 1)::numeric / v_pw)) FROM jsonb_array_elements(coalesce(v_d.formula -> 'plus', '[]'::jsonb)) e), '[]'::jsonb)
        INTO v_list;
      FOR v_part IN SELECT e FROM jsonb_array_elements(v_list) e LOOP
        IF NOT (v_frac ? (v_part ->> 0)) THEN v_ok := false; EXIT; END IF;
        v_pm := v_frac -> (v_part ->> 0);
        v_c := coalesce((p_vals ->> (v_part ->> 0))::numeric, 0) * (v_part ->> 1)::numeric;
        v_s := v_s + v_c * (v_pm ->> 0)::numeric; v_m := v_m + v_c * (v_pm ->> 1)::numeric; v_b := v_b + v_c * (v_pm ->> 2)::numeric;
        v_tot := v_tot + v_c;
      END LOOP;
      CONTINUE WHEN NOT v_ok;
      IF v_tot <= 0 THEN
        v_s := 0; v_m := 0; v_b := 0; v_tot := 0;
        FOR v_part IN SELECT e FROM jsonb_array_elements(v_list) e LOOP
          v_pm := v_frac -> (v_part ->> 0);
          v_c := (v_part ->> 1)::numeric;
          v_s := v_s + v_c * (v_pm ->> 0)::numeric; v_m := v_m + v_c * (v_pm ->> 1)::numeric; v_b := v_b + v_c * (v_pm ->> 2)::numeric;
          v_tot := v_tot + v_c;
        END LOOP;
      END IF;
      IF v_tot <= 0 THEN v_frac := v_frac || jsonb_build_object(v_d.key, '[0,0,1]'::jsonb);
      ELSE v_frac := v_frac || jsonb_build_object(v_d.key, jsonb_build_array(v_s / v_tot, v_m / v_tot, v_b / v_tot));
      END IF;
      v_moved := true;
    END LOOP;
    EXIT WHEN NOT v_moved OR v_pass >= 12;
  END LOOP;
  FOR v_e IN SELECT key, value FROM jsonb_each(v_frac) LOOP
    v_ps := round((v_e.value ->> 0)::numeric * 100)::integer;
    v_pmi := round((v_e.value ->> 1)::numeric * 100)::integer;
    v_pb := 100 - v_ps - v_pmi;
    IF v_pb < 0 THEN v_pmi := v_pmi + v_pb; v_pb := 0; END IF;
    v_out := v_out || jsonb_build_object(v_e.key, jsonb_build_object('spirit', v_ps, 'mind', v_pmi, 'body', v_pb));
  END LOOP;
  RETURN v_out;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_skill_tree(p_card uuid, p_vals jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The skill tree, figured from the formulas (Peter 2026-09-30 and 2026-10-01, decisions 1A 2A 3B). A skill's parents are
-- the trainable stats in its parts and its "plus" basics; rolled traits are never parents. A skill with no skill-parent
-- (a basic, or Hope, built only from traits) is a root: always open, mastery bar 3. Any other skill's mastery bar is the
-- sum of its parents' bars, and it opens when every parent is open and each parent stands at one third of its own bar
-- or more. It is second nature (mastered) when every parent is second nature and its own number reaches its bar.
-- Courage (parent Trust): bar 3, opens when Trust is 1. Solo Battle (Courage, Endurance): bar 6, opens its children at 2.
-- Sword (Courage, Endurance, Solo Battle, Swing arm, Grip, Footwork): bar 21; opens at Courage 1, Endurance 1,
-- Solo Battle 2, Swing arm 1, Grip 1, Footwork 1. Prayer (Shield of Faith, Breastplate, Stillness, Trust): bar 15.
-- Returns {key: {bar, opens_children_at, parents, open, second_nature}} for every trainable stat the card gives.
-- p_vals is rpg_sheet_values(character)->'values'. Used by rpg_sheet. Internal.
DECLARE
  v_defs   public.rpg_stat_definitions[];
  v_d      public.rpg_stat_definitions;
  v_skills text[];
  v_out    jsonb := '{}'::jsonb;
  v_pass   integer := 0;
  v_moved  boolean;
  v_par    text[];
  v_p      text;
  v_ok     boolean;
  v_bar    integer;
  v_pbar   integer;
  v_open   boolean;
  v_sn     boolean;
BEGIN
  v_defs := ARRAY(SELECT d FROM public.rpg_template_stat_defs(p_card) d WHERE d.trainable ORDER BY d.sort_order, d.key);
  v_skills := ARRAY(SELECT d.key FROM unnest(v_defs) d);
  LOOP
    v_pass := v_pass + 1; v_moved := false;
    FOREACH v_d IN ARRAY v_defs LOOP
      CONTINUE WHEN v_out ? v_d.key;
      v_par := ARRAY(SELECT DISTINCT e ->> 0
                       FROM jsonb_array_elements(coalesce(v_d.formula -> 'parts', '[]'::jsonb) || coalesce(v_d.formula -> 'plus', '[]'::jsonb)) e
                      WHERE (e ->> 0) = ANY (v_skills) ORDER BY 1);
      v_ok := true; v_bar := 0; v_open := true; v_sn := true;
      FOREACH v_p IN ARRAY v_par LOOP
        IF NOT (v_out ? v_p) THEN v_ok := false; EXIT; END IF;
        v_pbar := (v_out -> v_p ->> 'bar')::integer;
        v_bar := v_bar + v_pbar;
        v_open := v_open AND (v_out -> v_p ->> 'open')::boolean
                  AND coalesce((p_vals ->> v_p)::numeric, 0) >= v_pbar / 3;
        v_sn := v_sn AND (v_out -> v_p ->> 'second_nature')::boolean;
      END LOOP;
      CONTINUE WHEN NOT v_ok;
      IF cardinality(v_par) = 0 THEN v_bar := 3; END IF;
      v_sn := v_sn AND v_open AND coalesce((p_vals ->> v_d.key)::numeric, 0) >= v_bar;
      v_out := v_out || jsonb_build_object(v_d.key, jsonb_build_object(
        'bar', v_bar, 'opens_children_at', v_bar / 3, 'parents', to_jsonb(v_par), 'open', v_open, 'second_nature', v_sn));
      v_moved := true;
    END LOOP;
    EXIT WHEN NOT v_moved OR v_pass >= 20;
  END LOOP;
  RETURN v_out;
END;
$function$;
REVOKE ALL ON FUNCTION public.rpg_skill_tree(uuid, jsonb) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.rpg_sheet(p_character_id uuid, p_difficulty numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One character's whole sheet. Its stats are the ones its card gives it (rpg_template_stat_defs): every shared stat,
-- plus any that belong to the card it is made from or a card above it. A Human has only the shared ones.
-- The numbers come from rpg_sheet_values; this adds what the page shows (names, formulas, what a roll needs).
DECLARE
  v_c       record;
  v_calc    jsonb;
  v_defs    public.rpg_stat_definitions[];
  v_d       public.rpg_stat_definitions;
  v_vals    jsonb;
  v_bonus   jsonb;
  v_earned  jsonb;
  v_points  jsonb;
  v_names   jsonb;
  v_v       numeric;
  v_diff    numeric;
  v_nc      jsonb;
  v_stats   jsonb := '[]'::jsonb;
  v_kid     text;
  v_items   jsonb;
  v_pv      numeric;
  v_raw     jsonb;
  v_good    numeric;
  v_evil    numeric;
  v_basics  jsonb := '[]'::jsonb;
  v_mix     jsonb;
  v_tree    jsonb;
  v_sections jsonb;
  v_bulk    jsonb;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_c FROM public.rpg_characters WHERE id = p_character_id;
  IF NOT FOUND OR NOT public.rpg_can_see_character(p_character_id) THEN RAISE EXCEPTION 'character not found'; END IF;
  v_diff := coalesce(p_difficulty, public.rpg_setting('default_difficulty'));
  v_calc := public.rpg_sheet_values(p_character_id);
  v_vals := v_calc->'values'; v_raw := v_calc->'raw';
  v_bonus := v_calc->'bonus'; v_earned := v_calc->'earned'; v_points := v_calc->'points';
  v_defs := ARRAY(SELECT d FROM public.rpg_template_stat_defs(v_c.template_id) d ORDER BY d.sort_order, d.key);
  SELECT coalesce(jsonb_object_agg(t.key, t.name), '{}'::jsonb) INTO v_names
  FROM public.rpg_stat_definitions t WHERE t.agency_id = v_c.agency_id;
  -- each stat's section (rpg_section), the mix line (rpg_sheet_mix) and the parents a calculated stat is built from (rpg_stat_parents)
  SELECT coalesce(jsonb_object_agg(t.key, public.rpg_section(t.grp)), '{}'::jsonb) INTO v_sections
  FROM public.rpg_stat_definitions t WHERE t.agency_id = v_c.agency_id;
  v_mix := public.rpg_sheet_mix(v_c.template_id, v_vals);
  -- open / second nature for every skill (rpg_skill_tree, the one home of the tree)
  v_tree := public.rpg_skill_tree(v_c.template_id, v_vals);

  FOREACH v_d IN ARRAY v_defs LOOP
    CONTINUE WHEN v_d.side = 'evil' OR v_d.grp = 'basic';
    v_v := coalesce((v_vals->>v_d.key)::numeric, 0);
    -- Prayer and Bible Study face the difficulty plus the spiritual burden, as rpg_roll charges it (burden 6: 5 becomes 11)
    -- a weapon skill with a bulky weapon in hand rolls lower by the bulk past the handling (rpg_weapon_bulk), so its "needs" says so too
    v_bulk := CASE WHEN v_d.is_attack THEN public.rpg_weapon_bulk(p_character_id, v_d.key) END;
    v_nc := public.rpg_needed(greatest(v_v - coalesce((v_bulk->>'over')::numeric, 0), 0), v_diff + CASE WHEN v_d.spirit_discipline THEN coalesce(v_c.spiritual_burden, 0) ELSE 0 END);
    v_good := coalesce((v_raw->>v_d.key)::numeric, 0); v_evil := CASE WHEN v_d.pair_key IS NULL THEN 0 ELSE coalesce((v_raw->>v_d.pair_key)::numeric, 0) END;
    v_stats := v_stats || jsonb_build_object(
      'key', v_d.key, 'name', CASE WHEN v_d.pair_key IS NOT NULL AND v_evil > v_good THEN v_names->>v_d.pair_key ELSE v_d.name END,
      'pair_key', v_d.pair_key, 'side', CASE WHEN v_d.pair_key IS NULL THEN NULL WHEN v_evil > v_good THEN 'evil' ELSE 'good' END,
      'good_name', CASE WHEN v_d.pair_key IS NULL THEN NULL ELSE v_d.name END, 'evil_name', CASE WHEN v_d.pair_key IS NULL THEN NULL ELSE v_names->>v_d.pair_key END,
      'good', CASE WHEN v_d.pair_key IS NULL THEN NULL ELSE v_good END, 'evil', CASE WHEN v_d.pair_key IS NULL THEN NULL ELSE v_evil END, 'abbr', v_d.abbr, 'grp', v_d.grp, 'kind', v_d.kind, 'trainable', v_d.trainable,
      'value', v_v,
      'base', v_v - coalesce((v_bonus->>v_d.key)::numeric, 0) - coalesce((v_earned->>v_d.key)::numeric, 0),
      'item_bonus', coalesce((v_bonus->>v_d.key)::numeric, 0),
      'earned_levels', coalesce((v_earned->>v_d.key)::numeric, 0),
      'skill_points', round(coalesce((v_points->>v_d.key)::numeric, 0), 1),
      'next_level_cost', CASE WHEN v_d.trainable THEN public.rpg_level_cost(v_v::integer) ELSE NULL END,
      'needed', v_nc->'needed', 'critical', v_nc->'critical', 'bulk', v_bulk,
      'formula_text', public.rpg_formula_text(v_d.formula, v_names),
      'section', public.rpg_section(v_d.grp), 'tree', v_tree -> v_d.key, 'mix', CASE WHEN v_d.kind = 'derived' THEN v_mix -> v_d.key END,
      'parents', CASE WHEN v_d.kind = 'derived' THEN public.rpg_stat_parents(v_d.formula, v_vals, v_names, v_sections) END);
  END LOOP;

  -- the hidden basics (Swing arm, Grip, ...): not stats on the sheet, shown inside the skills built on them
  FOREACH v_d IN ARRAY v_defs LOOP
    CONTINUE WHEN v_d.grp <> 'basic';
    v_v := coalesce((v_vals->>v_d.key)::numeric, 0);
    v_basics := v_basics || jsonb_build_object('key', v_d.key, 'name', v_d.name, 'abbr', v_d.abbr, 'value', v_v,
      'skill_points', round(coalesce((v_points->>v_d.key)::numeric, 0), 1), 'next_level_cost', public.rpg_level_cost(v_v::integer), 'tree', v_tree -> v_d.key);
  END LOOP;

  SELECT k.name INTO v_kid FROM public.family_kids k WHERE k.id = v_c.kid_id;
  -- each item's row comes from rpg_item_row, the one writer of it (the Objects tab reads the same rows)
  SELECT coalesce(jsonb_agg(public.rpg_item_row(i.id) ORDER BY i.sort_order, i.created_at), '[]'::jsonb)
    INTO v_items FROM public.rpg_items i WHERE i.character_id = p_character_id;
  v_pv := (v_calc->>'vitality_max')::numeric;

  RETURN jsonb_build_object(
    'id', v_c.id, 'name', v_c.name, 'template_id', v_c.template_id, 'side', v_calc->>'side', 'kid_id', v_c.kid_id, 'kid_name', v_kid, 'is_npc', v_c.is_npc,
    'color', v_c.color, 'notes', v_c.notes, 'inputs', v_c.inputs,
    'vitality_max', v_pv, 'vitality_damage', v_c.vitality_damage, 'vitality_left', greatest(v_pv - v_c.vitality_damage, 0),
    'coins', jsonb_build_object('platinum', v_c.platinum, 'gold', v_c.gold, 'silver', v_c.silver, 'copper', v_c.copper),
    'difficulty', v_diff, 'crit_chance', public.rpg_setting('crit_chance'),
    'spiritual_burden', coalesce(v_c.spiritual_burden, 0),
    -- the armor of God pieces that wear (rpg_stat_definitions.guards): the Shield of Faith, the Breastplate, the Helmet
    'armor', (SELECT coalesce(jsonb_agg(public.rpg_armor_state(p_character_id, d.key) ORDER BY d.sort_order), '[]'::jsonb)
                FROM public.rpg_stat_definitions d WHERE d.agency_id = v_c.agency_id AND d.guards IS NOT NULL),
    'items', v_items, 'stats', v_stats, 'basics', v_basics,
    'object_cards', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name, 'worn', k.worn, 'weapon_key', k.weapon_key) ORDER BY k.sort_order, k.name), '[]'::jsonb)
                        FROM public.rpg_creatures k WHERE k.agency_id = v_c.agency_id AND k.is_active AND k.key <> 'object' AND public.rpg_is_object_card(k.id)));
END;
$function$;

UPDATE public.rpg_rules SET body = replace(replace(body,
 'and each level it gains adds one whole point to every skill built on it.',
 'and the basics under a skill add their average to it, rounded down.'),
 '*Sword is (Courage + Endurance + Solo Battle + Agility + Strength) ÷ 5, rounded down, plus Swing arm, Grip and Footwork. Karen''s Sword 6 becomes 7 the day her Footwork reaches 1, and so does her Dagger.*',
 '*Sword is (Courage + Endurance + Solo Battle + Agility + Strength) ÷ 5, rounded down, plus the average of Swing arm, Grip and Footwork, rounded down. With only her Footwork at 1 the average is 0.33, so Karen''s Sword stays 6. With all three at 1 it becomes 7, and her Dagger goes up by 1 too.*')
 WHERE key = 'basics';
DO $g$ BEGIN
  IF (SELECT body FROM public.rpg_rules WHERE key = 'basics') NOT LIKE '%add their average to it, rounded down.%'
     OR (SELECT body FROM public.rpg_rules WHERE key = 'basics') NOT LIKE '%With all three at 1 it becomes 7%' THEN
    RAISE EXCEPTION 'basics rule card text did not match';
  END IF;
END $g$;

