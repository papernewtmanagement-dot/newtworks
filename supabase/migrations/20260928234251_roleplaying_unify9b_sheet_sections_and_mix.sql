-- roleplaying_unify9b_sheet_sections_and_mix
-- Sheet redesign, step 2, database side (Peter 2026-09-28, "defaults" = 3A): every stat carries its section (Spirit,
-- Mind, Body, Derived, Skills), every calculated stat carries its mix (how much of its number is Spirit, Mind and
-- Body, weighted by what each part actually contributes) and its parents (what it is built from, with the
-- character's numbers). One home for each: rpg_section, rpg_sheet_mix, rpg_stat_parents; rpg_sheet and
-- rpg_rules_page read them. The three spiritual basics are marked spiritual (their side on the mix line).

-- 1. The spiritual basics' side
UPDATE public.rpg_stat_definitions SET energy_type = 'spiritual'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key IN ('stillness', 'attention', 'trust');

-- 2. Which section a stat group shows in
CREATE OR REPLACE FUNCTION public.rpg_section(p_grp text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  -- The sheet's sections (Peter 2026-09-28): the rolled traits in Spirit (the nine fruits and the root pair, stored as
  -- grp strength), Mind and Body; the numbers figured only from traits in Derived; every skill, ability and armor piece
  -- together in Skills. Basics are hidden rows: they show only inside a skill's parents.
  SELECT CASE p_grp WHEN 'strength' THEN 'Spirit' WHEN 'mind' THEN 'Mind' WHEN 'physical' THEN 'Body'
                    WHEN 'derived' THEN 'Derived' WHEN 'basic' THEN 'Basic' ELSE 'Skills' END;
$fn$;

-- 3. The mix line
CREATE OR REPLACE FUNCTION public.rpg_sheet_mix(p_card uuid, p_vals jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
-- The mix line: how much of each stat's number is Spirit, Mind and Body. A rolled or fixed stat is all one side (the
-- nine fruits, the root pair and the Sword of the Spirit are Spirit; Intelligence, Focus, Memory, Perception Mind;
-- Strength, Agility, Toughness Body). A calculated stat takes the mix of what it is built from, each part weighted by
-- what it actually contributes (its number × its weight, the "plus" basics included), so a basic still at 0 adds
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
      FOR v_part IN SELECT e FROM jsonb_array_elements(coalesce(v_d.formula -> 'parts', '[]'::jsonb) || coalesce(v_d.formula -> 'plus', '[]'::jsonb)) e LOOP
        IF NOT (v_frac ? (v_part ->> 0)) THEN v_ok := false; EXIT; END IF;
        v_pm := v_frac -> (v_part ->> 0);
        v_c := coalesce((p_vals ->> (v_part ->> 0))::numeric, 0) * (v_part ->> 1)::numeric;
        v_s := v_s + v_c * (v_pm ->> 0)::numeric; v_m := v_m + v_c * (v_pm ->> 1)::numeric; v_b := v_b + v_c * (v_pm ->> 2)::numeric;
        v_tot := v_tot + v_c;
      END LOOP;
      CONTINUE WHEN NOT v_ok;
      IF v_tot <= 0 THEN
        v_s := 0; v_m := 0; v_b := 0; v_tot := 0;
        FOR v_part IN SELECT e FROM jsonb_array_elements(coalesce(v_d.formula -> 'parts', '[]'::jsonb) || coalesce(v_d.formula -> 'plus', '[]'::jsonb)) e LOOP
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
$fn$;
REVOKE ALL ON FUNCTION public.rpg_sheet_mix(uuid, jsonb) FROM PUBLIC, anon, authenticated;

-- 4. What a calculated stat is built from
CREATE OR REPLACE FUNCTION public.rpg_stat_parents(p_formula jsonb, p_vals jsonb, p_names jsonb, p_sections jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $fn$
  -- The parents a calculated stat is built from, with the character's numbers: the averaged parts in formula order,
  -- then the basics added whole (plus true). Each carries its section (Spirit, Mind, Body, Derived, Skills, Basic) so
  -- the sheet can color it. Karen's Sword: Courage 8, Endurance 7, Solo Battle 7, Agility 1, Strength 10, then
  -- Swing arm 0, Grip 0, Footwork 0. Used by rpg_sheet.
  SELECT CASE WHEN p_formula IS NULL THEN NULL ELSE coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'key', x.e ->> 0, 'name', coalesce(p_names ->> (x.e ->> 0), x.e ->> 0),
             'value', coalesce((p_vals ->> (x.e ->> 0))::numeric, 0), 'weight', (x.e ->> 1)::numeric,
             'section', p_sections ->> (x.e ->> 0), 'plus', x.plus) ORDER BY x.plus, x.ord)
      FROM (SELECT e, ord, false AS plus FROM jsonb_array_elements(coalesce(p_formula -> 'parts', '[]'::jsonb)) WITH ORDINALITY AS t(e, ord)
            UNION ALL
            SELECT e, ord, true FROM jsonb_array_elements(coalesce(p_formula -> 'plus', '[]'::jsonb)) WITH ORDINALITY AS t(e, ord)) x),
    '[]'::jsonb) END;
$fn$;

-- 5. rpg_sheet: section, mix and parents on every stat (patched on the live body by anchors)
DO $do$
DECLARE v_src text; v_n int;
BEGIN
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rpg_sheet';
  IF v_src LIKE '%rpg_sheet_mix%' THEN RETURN; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '  v_basics  jsonb := ''\[\]''::jsonb;\nBEGIN', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_sheet anchor 1 found % times', v_n; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '  SELECT coalesce\(jsonb_object_agg\(t\.key, t\.name\), ''\{\}''::jsonb\) INTO v_names\n  FROM public\.rpg_stat_definitions t WHERE t\.agency_id = v_c\.agency_id;\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_sheet anchor 2 found % times', v_n; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '      ''formula_text'', public\.rpg_formula_text\(v_d\.formula, v_names\)\);', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_sheet anchor 3 found % times', v_n; END IF;
  v_src := replace(v_src, E'  v_basics  jsonb := ''[]''::jsonb;\nBEGIN',
                          E'  v_basics  jsonb := ''[]''::jsonb;\n  v_mix     jsonb;\n  v_sections jsonb;\nBEGIN');
  v_src := replace(v_src, E'  SELECT coalesce(jsonb_object_agg(t.key, t.name), ''{}''::jsonb) INTO v_names\n  FROM public.rpg_stat_definitions t WHERE t.agency_id = v_c.agency_id;\n',
                          E'  SELECT coalesce(jsonb_object_agg(t.key, t.name), ''{}''::jsonb) INTO v_names\n  FROM public.rpg_stat_definitions t WHERE t.agency_id = v_c.agency_id;\n  -- each stat''s section (rpg_section), the mix line (rpg_sheet_mix) and the parents a calculated stat is built from (rpg_stat_parents)\n  SELECT coalesce(jsonb_object_agg(t.key, public.rpg_section(t.grp)), ''{}''::jsonb) INTO v_sections\n  FROM public.rpg_stat_definitions t WHERE t.agency_id = v_c.agency_id;\n  v_mix := public.rpg_sheet_mix(v_c.template_id, v_vals);\n');
  v_src := replace(v_src, '      ''formula_text'', public.rpg_formula_text(v_d.formula, v_names));',
                          E'      ''formula_text'', public.rpg_formula_text(v_d.formula, v_names),\n      ''section'', public.rpg_section(v_d.grp), ''mix'', CASE WHEN v_d.kind = ''derived'' THEN v_mix -> v_d.key END,\n      ''parents'', CASE WHEN v_d.kind = ''derived'' THEN public.rpg_stat_parents(v_d.formula, v_vals, v_names, v_sections) END);');
  EXECUTE format('CREATE OR REPLACE FUNCTION public.rpg_sheet(p_character_id uuid, p_difficulty numeric DEFAULT NULL::numeric) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS %L', v_src);
END $do$;

-- 6. The Rules tab groups stats by the same sections
DO $do$
DECLARE v_src text; v_n int;
BEGIN
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rpg_rules_page';
  IF v_src LIKE '%rpg_section%' THEN RETURN; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '''trainable'', d\.trainable, ''default_value'', d\.default_value,\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_rules_page anchor found % times', v_n; END IF;
  v_src := replace(v_src, E'''trainable'', d.trainable, ''default_value'', d.default_value,\n',
                          E'''trainable'', d.trainable, ''default_value'', d.default_value, ''section'', public.rpg_section(d.grp),\n');
  EXECUTE format('CREATE OR REPLACE FUNCTION public.rpg_rules_page(p_max_level integer DEFAULT 30) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS %L', v_src);
END $do$;
