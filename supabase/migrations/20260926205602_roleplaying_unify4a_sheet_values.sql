-- The sheet's numbers, figured once. rpg_sheet shows them; the fight functions read them.
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
-- Karen: values.EE 5, vitality_max 41. A Bramblemaw: values.EE 8, values.claw 10, values.IG 8, vitality_max 149.
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
  v_defs := ARRAY(SELECT d FROM public.rpg_template_stat_defs(v_c.template_key) d ORDER BY d.sort_order, d.key);

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
    v_v := coalesce((v_c.inputs->>v_d.key)::numeric, v_d.default_value)
         + coalesce((v_bonus->>v_d.key)::numeric, 0) + coalesce((v_earned->>v_d.key)::numeric, 0);
    v_vals := v_vals || jsonb_build_object(v_d.key, v_v);
  END LOOP;

  -- paired Spirit traits: the net (winner minus loser) feeds every formula; the label is the winner's.
  -- The root pair (Connection with God / Fascination with Evil) says which side the being is on.
  v_raw := v_vals;
  FOREACH v_d IN ARRAY v_defs LOOP
    CONTINUE WHEN v_d.side IS DISTINCT FROM 'good' OR v_d.pair_key IS NULL;
    v_good := coalesce((v_raw->>v_d.key)::numeric, 0); v_evil := coalesce((v_raw->>v_d.pair_key)::numeric, 0);
    v_vals := v_vals || jsonb_build_object(v_d.key, abs(v_good - v_evil), v_d.pair_key, 0);
    IF v_d.key = 'CG' AND v_evil > v_good THEN v_side := 'evil'; END IF;
  END LOOP;

  -- derived stats, resolved in dependency order (a stat waits until every part it uses is known)
  LOOP
    v_pass := v_pass + 1; v_moved := false;
    FOREACH v_d IN ARRAY v_defs LOOP
      CONTINUE WHEN v_d.kind <> 'derived' OR v_vals ? v_d.key;
      v_ok := true; v_total := 0;
      FOR v_part IN SELECT e FROM jsonb_array_elements(v_d.formula->'parts') e LOOP
        IF NOT (v_vals ? (v_part->>0)) THEN v_ok := false; EXIT; END IF;
        v_total := v_total + (v_vals->>(v_part->>0))::numeric * (v_part->>1)::numeric;
      END LOOP;
      CONTINUE WHEN NOT v_ok;
      v_div := coalesce((v_d.formula->>'div')::numeric, 1);
      v_v := floor(v_total / v_div)
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
REVOKE ALL ON FUNCTION public.rpg_sheet_values(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_sheet_values(uuid) TO service_role;

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
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_c FROM public.rpg_characters WHERE id = p_character_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'character not found'; END IF;
  v_diff := coalesce(p_difficulty, public.rpg_setting('default_difficulty'));
  v_calc := public.rpg_sheet_values(p_character_id);
  v_vals := v_calc->'values'; v_raw := v_calc->'raw';
  v_bonus := v_calc->'bonus'; v_earned := v_calc->'earned'; v_points := v_calc->'points';
  v_defs := ARRAY(SELECT d FROM public.rpg_template_stat_defs(v_c.template_key) d ORDER BY d.sort_order, d.key);
  SELECT coalesce(jsonb_object_agg(t.key, t.name), '{}'::jsonb) INTO v_names
  FROM public.rpg_stat_definitions t WHERE t.agency_id = v_c.agency_id;

  FOREACH v_d IN ARRAY v_defs LOOP
    CONTINUE WHEN v_d.side = 'evil';
    v_v := coalesce((v_vals->>v_d.key)::numeric, 0);
    v_nc := public.rpg_needed(v_v, v_diff);
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
      'needed', v_nc->'needed', 'critical', v_nc->'critical',
      'formula_text', public.rpg_formula_text(v_d.formula, v_names));
  END LOOP;

  SELECT k.name INTO v_kid FROM public.family_kids k WHERE k.id = v_c.kid_id;
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'stat_key', i.stat_key,
           'stat_name', v_names->>i.stat_key, 'bonus', i.bonus, 'uses_left', i.uses_left, 'equipped', i.equipped, 'notes', i.notes)
           ORDER BY i.sort_order, i.created_at), '[]'::jsonb)
    INTO v_items FROM public.rpg_items i WHERE i.character_id = p_character_id;
  v_pv := (v_calc->>'vitality_max')::numeric;

  RETURN jsonb_build_object(
    'id', v_c.id, 'name', v_c.name, 'template_key', v_c.template_key, 'side', v_calc->>'side', 'kid_id', v_c.kid_id, 'kid_name', v_kid, 'is_npc', v_c.is_npc,
    'color', v_c.color, 'notes', v_c.notes, 'inputs', v_c.inputs,
    'vitality_max', v_pv, 'vitality_damage', v_c.vitality_damage, 'vitality_left', greatest(v_pv - v_c.vitality_damage, 0),
    'coins', jsonb_build_object('platinum', v_c.platinum, 'gold', v_c.gold, 'silver', v_c.silver, 'copper', v_c.copper),
    'difficulty', v_diff, 'crit_chance', public.rpg_setting('crit_chance'),
    'items', v_items, 'stats', v_stats);
END;
$function$;
