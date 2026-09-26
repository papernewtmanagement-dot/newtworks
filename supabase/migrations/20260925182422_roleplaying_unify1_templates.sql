-- Roleplaying unification, step 1: templates (Peter 2026-09-25, spec "Roleplaying character model 2.0" <unification>).
-- A creature card (rpg_creatures) is a template. It may sit under a parent card (Wolf above every wolf) and it carries a
-- blueprint: the per-input ranges a character made from it is rolled from. A boss lists fixed numbers instead.
-- Every character is made from a card (rpg_characters.template_key; the players' characters are Human).
-- A stat definition may belong to one card and every card under it (rpg_stat_definitions.template_key; null = everyone).
-- rpg_new_character makes a character from a card; rpg_roll_inputs(card) is the one generator.

-- 1. Cards become templates. The printed d20 numbers are reading only, so a card without any (Human) leaves them
--    empty instead of carrying made-up ones.
ALTER TABLE public.rpg_creatures ADD COLUMN IF NOT EXISTS parent_key text;
ALTER TABLE public.rpg_creatures ADD COLUMN IF NOT EXISTS blueprint jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE public.rpg_creatures
  ALTER COLUMN armor_class DROP NOT NULL,
  ALTER COLUMN hit_points  DROP NOT NULL,
  ALTER COLUMN str_score   DROP NOT NULL,
  ALTER COLUMN dex_score   DROP NOT NULL,
  ALTER COLUMN con_score   DROP NOT NULL,
  ALTER COLUMN int_score   DROP NOT NULL,
  ALTER COLUMN wis_score   DROP NOT NULL,
  ALTER COLUMN cha_score   DROP NOT NULL;
ALTER TABLE public.rpg_creatures ADD CONSTRAINT rpg_creatures_parent_fkey
  FOREIGN KEY (agency_id, parent_key) REFERENCES public.rpg_creatures (agency_id, key) ON UPDATE CASCADE;
COMMENT ON COLUMN public.rpg_creatures.parent_key IS 'The card this card is made from (a Grey Wolf card under Wolf). The parent''s blueprint and its own stats pass down; this card''s entries win.';
COMMENT ON COLUMN public.rpg_creatures.blueprint IS 'How a character made from this card is rolled. {stat key: number} is fixed, the same every time (a boss). {stat key: [low, high]} rolls evenly inside the range. Stats left out come from the parent card, then the standard roll (d100 ÷ 10, rounded up).';

-- 2. Human, the first card: every player character is made from it. An empty blueprint, so every trait rolls the
--    standard way. Shown to players, because players make their characters from it.
INSERT INTO public.rpg_creatures (key, name, size, creature_type, color, shown_to_players, sort_order, blueprint)
VALUES ('human', 'Human', 'Medium', 'humanoid', '#737A59', true, 0, '{}'::jsonb)
ON CONFLICT (agency_id, key) DO NOTHING;

-- 3. Every character is made from a card. The four player characters are Human.
ALTER TABLE public.rpg_characters ADD COLUMN IF NOT EXISTS template_key text NOT NULL DEFAULT 'human';
ALTER TABLE public.rpg_characters ADD CONSTRAINT rpg_characters_template_fkey
  FOREIGN KEY (agency_id, template_key) REFERENCES public.rpg_creatures (agency_id, key) ON UPDATE CASCADE;
COMMENT ON COLUMN public.rpg_characters.template_key IS 'The card this character is made from (rpg_creatures.key). Its inputs came from that card''s blueprint, and it has that card''s own stats.';

-- 4. A stat can belong to one card and every card under it (a claw skill for clawed creatures). Null = everyone.
ALTER TABLE public.rpg_stat_definitions ADD COLUMN IF NOT EXISTS template_key text;
ALTER TABLE public.rpg_stat_definitions ADD CONSTRAINT rpg_stat_definitions_template_fkey
  FOREIGN KEY (agency_id, template_key) REFERENCES public.rpg_creatures (agency_id, key) ON UPDATE CASCADE;
COMMENT ON COLUMN public.rpg_stat_definitions.template_key IS 'Null: every character has this stat. A card key: only characters made from that card, or from a card under it.';

-- 5. The chain, the blueprint and the stats a card gives. One function each; everything else asks them.
CREATE OR REPLACE FUNCTION public.rpg_template_chain(p_template_key text)
 RETURNS text[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A card and every card above it, nearest first. A Grey Wolf card made from Wolf gives {grey_wolf, wolf}; Human
-- gives {human}. The one place that says what a card is made of. Stops at ten levels and never visits a card twice.
WITH RECURSIVE up AS (
  SELECT c.key, c.parent_key, 1 AS depth, ARRAY[c.key] AS path
    FROM public.rpg_creatures c
   WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.key = p_template_key
  UNION ALL
  SELECT c.key, c.parent_key, up.depth + 1, up.path || c.key
    FROM up
    JOIN public.rpg_creatures c ON c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.key = up.parent_key
   WHERE up.depth < 10 AND NOT c.key = ANY (up.path)
)
SELECT coalesce(array_agg(key ORDER BY depth), '{}'::text[]) FROM up;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_template_blueprint(p_template_key text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A card's whole blueprint, with what it takes from the cards above it: the parent's entries first, the card's own win.
-- Wolf {"ST": [8, 12], "AG": [6, 9]} above a Grey Wolf {"ST": [9, 11]} gives {"ST": [9, 11], "AG": [6, 9]}.
SELECT coalesce(jsonb_object_agg(e.key, e.value ORDER BY t.depth DESC), '{}'::jsonb)
  FROM unnest(public.rpg_template_chain(p_template_key)) WITH ORDINALITY AS t(key, depth)
  JOIN public.rpg_creatures c ON c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.key = t.key
 CROSS JOIN LATERAL jsonb_each(c.blueprint) AS e;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_template_stat_defs(p_template_key text)
 RETURNS SETOF public.rpg_stat_definitions
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The stats a character made from this card has: every shared one (template_key null) plus the ones that belong to
-- the card or a card above it. A claw skill kept on a clawed parent reaches every card under it; a Human has none.
-- The sheet, the generator and the checks all ask this.
SELECT d.*
  FROM public.rpg_stat_definitions d
 WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND (d.template_key IS NULL OR d.template_key = ANY (public.rpg_template_chain(p_template_key)));
$function$;

-- 6. Guard a card's parent and blueprint before they save.
CREATE OR REPLACE FUNCTION public.rpg_creatures_template_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Parent: a card can never end up above itself (Wolf under Grey Wolf under Wolf is refused).
-- Blueprint: each entry is a stat key and a whole number, fixed ({"ST": 10}, the same every time), or [low, high],
-- rolled evenly ({"ST": [8, 12]} gives 8 to 12). Only rolled or fixed stats this card has. A calculated stat such as
-- Physical Vitality comes from the sheet, never the blueprint.
DECLARE
  v_key text;
  v_val jsonb;
  v_lo  numeric;
  v_hi  numeric;
BEGIN
  IF NEW.parent_key IS NOT NULL
     AND (NEW.parent_key = NEW.key OR NEW.key = ANY (public.rpg_template_chain(NEW.parent_key))) THEN
    RAISE EXCEPTION '% cannot be made from %: it would sit above itself', NEW.name, NEW.parent_key;
  END IF;
  IF NEW.blueprint IS NULL OR jsonb_typeof(NEW.blueprint) <> 'object' THEN
    RAISE EXCEPTION '%: a blueprint lists stats and their numbers', NEW.name;
  END IF;
  FOR v_key, v_val IN SELECT b.key, b.value FROM jsonb_each(NEW.blueprint) AS b LOOP
    IF NOT EXISTS (SELECT 1 FROM public.rpg_template_stat_defs(NEW.parent_key) d
                    WHERE d.key = v_key AND d.kind IN ('rolled','fixed'))
       AND NOT EXISTS (SELECT 1 FROM public.rpg_stat_definitions d
                        WHERE d.agency_id = NEW.agency_id AND d.template_key = NEW.key
                          AND d.key = v_key AND d.kind IN ('rolled','fixed')) THEN
      RAISE EXCEPTION '% blueprint: % is not a rolled or fixed stat this card has', NEW.name, v_key;
    END IF;
    IF jsonb_typeof(v_val) = 'number' THEN
      v_lo := (v_val #>> '{}')::numeric;
      v_hi := v_lo;
    ELSIF jsonb_typeof(v_val) = 'array' AND jsonb_array_length(v_val) = 2
          AND jsonb_typeof(v_val -> 0) = 'number' AND jsonb_typeof(v_val -> 1) = 'number' THEN
      v_lo := (v_val ->> 0)::numeric;
      v_hi := (v_val ->> 1)::numeric;
    ELSE
      RAISE EXCEPTION '% blueprint: % must be a number or [low, high]', NEW.name, v_key;
    END IF;
    IF v_lo < 0 OR v_hi < v_lo OR v_lo <> trunc(v_lo) OR v_hi <> trunc(v_hi) THEN
      RAISE EXCEPTION '% blueprint: % needs whole numbers, low first (got %)', NEW.name, v_key, v_val;
    END IF;
  END LOOP;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS rpg_creatures_template_check ON public.rpg_creatures;
CREATE TRIGGER rpg_creatures_template_check
  BEFORE INSERT OR UPDATE OF parent_key, blueprint ON public.rpg_creatures
  FOR EACH ROW EXECUTE FUNCTION public.rpg_creatures_template_check();

-- 7. The one generator, now by card. Callers: rpg_new_character and rpg_reroll_character (both below), nothing in
--    src/ or the edge functions. The no-argument version goes; the guard at the end fails if any caller is left.
DROP FUNCTION IF EXISTS public.rpg_roll_inputs();
CREATE FUNCTION public.rpg_roll_inputs(p_template_key text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A new character's inputs from the card it is made from. For each rolled or fixed stat the card gives:
-- a blueprint number is fixed (the same every time, the way a boss is made); a range [low, high] rolls evenly inside
-- it ([8, 12] gives 8, 9, 10, 11 or 12); anything left out follows the standard rule: a rolled stat is d100 ÷ 10,
-- rounded up (a 47 makes 5, so 1 to 10), and a fixed one starts at its default (Sword of the Spirit 1).
SELECT public.require_login('family');
  SELECT coalesce(jsonb_object_agg(d.key,
           CASE jsonb_typeof(b.bp -> d.key)
             WHEN 'number' THEN (b.bp ->> d.key)::numeric
             WHEN 'array'  THEN (b.bp -> d.key ->> 0)::numeric
                                + floor(random() * ((b.bp -> d.key ->> 1)::numeric - (b.bp -> d.key ->> 0)::numeric + 1))
             ELSE CASE WHEN d.kind = 'rolled'
                       THEN ceil((floor(random() * public.rpg_setting('strength_roll_max')) + 1) / public.rpg_setting('strength_roll_divisor'))
                       ELSE d.default_value END
           END), '{}'::jsonb)
    FROM public.rpg_template_stat_defs(p_template_key) d
   CROSS JOIN (SELECT public.rpg_template_blueprint(p_template_key) AS bp) b
   WHERE d.kind IN ('rolled','fixed');
$function$;

-- 8. Making a character takes a card (Human when none is named). The old three-argument version goes in the same
--    breath so a call with three arguments has exactly one function to reach.
DROP FUNCTION IF EXISTS public.rpg_new_character(text, uuid, boolean);
CREATE FUNCTION public.rpg_new_character(p_name text, p_kid_id uuid DEFAULT NULL::uuid, p_is_npc boolean DEFAULT false, p_template_key text DEFAULT 'human'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Makes a character from a card. Its inputs come from rpg_roll_inputs(card): a Human rolls every trait d100 ÷ 10,
-- rounded up (a 47 makes 5); a card with ranges or fixed numbers rolls inside them.
-- Players may use a card that has been shown to them; the game master may use any card on the list.
DECLARE
  v_id      uuid;
  v_n       integer;
  v_key     text;
  v_active  boolean;
  v_shown   boolean;
  v_palette text[] := ARRAY['#737A59','#A88B5F','#5E7A77','#6E5B7A','#A87A75','#255C99','#2E8B57','#D4A017'];
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF coalesce(btrim(p_name), '') = '' THEN RAISE EXCEPTION 'name required'; END IF;
  SELECT key, is_active, shown_to_players INTO v_key, v_active, v_shown
    FROM public.rpg_creatures
   WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = coalesce(p_template_key, 'human');
  IF v_key IS NULL OR NOT v_active THEN RAISE EXCEPTION 'that card is not on the list'; END IF;
  IF NOT v_shown AND NOT public.family_is_parent() THEN RAISE EXCEPTION 'that card has not been shown to players'; END IF;
  SELECT count(*) INTO v_n FROM public.rpg_characters WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';
  INSERT INTO public.rpg_characters (name, kid_id, is_npc, template_key, inputs, color)
  VALUES (btrim(p_name), p_kid_id, coalesce(p_is_npc, false), v_key, public.rpg_roll_inputs(v_key), v_palette[(v_n % 8) + 1])
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.rpg_new_character(text, uuid, boolean, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpg_reroll_character(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A fresh set of inputs from the character's own card: a Human rolls every trait again; a fixed card gives the same numbers.
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF NOT public.family_is_parent() AND EXISTS (SELECT 1 FROM public.rpg_rolls WHERE character_id = p_character_id) THEN
    RAISE EXCEPTION 'this character has already played; ask a parent to re-roll';
  END IF;
  UPDATE public.rpg_characters SET inputs = public.rpg_roll_inputs(template_key) WHERE id = p_character_id;
  RETURN public.rpg_sheet(p_character_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_set_input(p_character_id uuid, p_key text, p_value integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_kind text;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'parents only'; END IF;
  SELECT d.kind INTO v_kind
    FROM public.rpg_characters c
   CROSS JOIN LATERAL public.rpg_template_stat_defs(c.template_key) d
   WHERE c.id = p_character_id AND d.key = p_key;
  IF v_kind IS NULL THEN RAISE EXCEPTION 'this character does not have that stat'; END IF;
  IF v_kind NOT IN ('rolled','fixed') THEN RAISE EXCEPTION 'that stat is calculated, not set'; END IF;
  UPDATE public.rpg_characters SET inputs = inputs || jsonb_build_object(p_key, p_value) WHERE id = p_character_id;
  RETURN public.rpg_sheet(p_character_id);
END;
$function$;

-- 9. The sheet shows the stats the character's card gives it (all of them for a Human, as before).
CREATE OR REPLACE FUNCTION public.rpg_sheet(p_character_id uuid, p_difficulty numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One character's whole sheet. Its stats are the ones its card gives it (rpg_template_stat_defs): every shared stat,
-- plus any that belong to the card it is made from or a card above it. A Human has only the shared ones.
DECLARE
  v_c       record;
  v_defs    public.rpg_stat_definitions[];
  v_d       public.rpg_stat_definitions;
  v_vals    jsonb := '{}'::jsonb;
  v_bonus   jsonb;
  v_earned  jsonb;
  v_points  jsonb;
  v_names   jsonb;
  v_pass    integer := 0;
  v_moved   boolean;
  v_part    jsonb;
  v_total   numeric;
  v_ok      boolean;
  v_div     numeric;
  v_v       numeric;
  v_diff    numeric;
  v_nc      jsonb;
  v_stats   jsonb := '[]'::jsonb;
  v_kid     text;
  v_items   jsonb;
  v_pv      numeric;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_c FROM public.rpg_characters WHERE id = p_character_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'character not found'; END IF;
  v_diff := coalesce(p_difficulty, public.rpg_setting('default_difficulty'));
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
  SELECT coalesce(jsonb_object_agg(t.key, t.name), '{}'::jsonb) INTO v_names
  FROM public.rpg_stat_definitions t WHERE t.agency_id = v_c.agency_id;

  -- rolled and fixed stats come straight from the character
  FOREACH v_d IN ARRAY v_defs LOOP
    CONTINUE WHEN v_d.kind NOT IN ('rolled','fixed');
    v_v := coalesce((v_c.inputs->>v_d.key)::numeric, v_d.default_value)
         + coalesce((v_bonus->>v_d.key)::numeric, 0) + coalesce((v_earned->>v_d.key)::numeric, 0);
    v_vals := v_vals || jsonb_build_object(v_d.key, v_v);
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

  FOREACH v_d IN ARRAY v_defs LOOP
    v_v := coalesce((v_vals->>v_d.key)::numeric, 0);
    v_nc := public.rpg_needed(v_v, v_diff);
    v_stats := v_stats || jsonb_build_object(
      'key', v_d.key, 'name', v_d.name, 'abbr', v_d.abbr, 'grp', v_d.grp, 'kind', v_d.kind, 'trainable', v_d.trainable,
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
  v_pv := coalesce((v_vals->>'PV')::numeric, 0);

  RETURN jsonb_build_object(
    'id', v_c.id, 'name', v_c.name, 'template_key', v_c.template_key, 'kid_id', v_c.kid_id, 'kid_name', v_kid, 'is_npc', v_c.is_npc,
    'color', v_c.color, 'notes', v_c.notes, 'inputs', v_c.inputs,
    'vitality_max', v_pv, 'vitality_damage', v_c.vitality_damage, 'vitality_left', greatest(v_pv - v_c.vitality_damage, 0),
    'coins', jsonb_build_object('platinum', v_c.platinum, 'gold', v_c.gold, 'silver', v_c.silver, 'copper', v_c.copper),
    'difficulty', v_diff, 'crit_chance', public.rpg_setting('crit_chance'),
    'items', v_items, 'stats', v_stats);
END;
$function$;

-- 10. The card shows how one is made (its parent and whole blueprint) to the game master, and leaves out a printed
--     d20 block the card does not have.
CREATE OR REPLACE FUNCTION public.rpg_creature_card(p_creature_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_gm   boolean := public.family_is_parent();
  v_c    public.rpg_creatures%ROWTYPE;
  v_card jsonb;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_c FROM public.rpg_creatures
   WHERE id = p_creature_id AND agency_id = '126794dd-25ff-47d2-a436-724499733365' AND is_active;
  IF NOT FOUND OR NOT (v_gm OR v_c.shown_to_players) THEN RETURN NULL; END IF;

  v_card := jsonb_build_object(
    'id', v_c.id, 'key', v_c.key, 'name', v_c.name, 'color', v_c.color, 'is_gm', v_gm,
    'scholarly_name', v_c.scholarly_name, 'whispered_label', v_c.whispered_label,
    'whispered_names', to_jsonb(v_c.whispered_names), 'haunts', v_c.haunts,
    'epigraph', v_c.epigraph, 'lore', v_c.lore);
  v_card := v_card || jsonb_build_object('image_path', v_c.image_path);
  IF NOT v_gm THEN RETURN v_card; END IF;

  RETURN v_card || jsonb_build_object(
    'shown_to_players', v_c.shown_to_players,
    'source_manual_id', v_c.source_manual_id,
    'card_title', v_c.card_title,
    'type_line', v_c.size || ' ' || v_c.creature_type || coalesce(', ' || v_c.alignment, ''),
    'armor_text', v_c.armor_class || coalesce(' (' || v_c.armor_note || ')', ''),
    'hit_points_text', v_c.hit_points || coalesce(' (' || v_c.hit_dice || ')', ''),
    'speed_text', v_c.speed_ft || ' ft.'
        || coalesce(', burrow ' || v_c.burrow_ft || ' ft.', '') || coalesce(', climb ' || v_c.climb_ft || ' ft.', '')
        || coalesce(', fly ' || v_c.fly_ft || ' ft.', '') || coalesce(', swim ' || v_c.swim_ft || ' ft.', ''),
    'abilities', CASE WHEN v_c.str_score IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(
        jsonb_build_object('key', 'str', 'label', 'STR', 'score', v_c.str_score, 'mod', floor((v_c.str_score - 10) / 2.0)::int),
        jsonb_build_object('key', 'dex', 'label', 'DEX', 'score', v_c.dex_score, 'mod', floor((v_c.dex_score - 10) / 2.0)::int),
        jsonb_build_object('key', 'con', 'label', 'CON', 'score', v_c.con_score, 'mod', floor((v_c.con_score - 10) / 2.0)::int),
        jsonb_build_object('key', 'int', 'label', 'INT', 'score', v_c.int_score, 'mod', floor((v_c.int_score - 10) / 2.0)::int),
        jsonb_build_object('key', 'wis', 'label', 'WIS', 'score', v_c.wis_score, 'mod', floor((v_c.wis_score - 10) / 2.0)::int),
        jsonb_build_object('key', 'cha', 'label', 'CHA', 'score', v_c.cha_score, 'mod', floor((v_c.cha_score - 10) / 2.0)::int)) END,
    'saving_throws_text', (SELECT string_agg(initcap(e->>'ability') || ' ' || CASE WHEN (e->>'bonus')::int < 0 THEN '−' ELSE '+' END
                             || abs((e->>'bonus')::int), ', ' ORDER BY o) FROM jsonb_array_elements(v_c.saving_throws) WITH ORDINALITY AS t(e, o)),
    'skills_text', (SELECT string_agg((e->>'name') || ' ' || CASE WHEN (e->>'bonus')::int < 0 THEN '−' ELSE '+' END
                      || abs((e->>'bonus')::int), ', ' ORDER BY o) FROM jsonb_array_elements(v_c.skills) WITH ORDINALITY AS t(e, o)),
    'damage_vulnerabilities', v_c.damage_vulnerabilities,
    'damage_resistances', v_c.damage_resistances,
    'damage_immunities', v_c.damage_immunities,
    'condition_immunities', v_c.condition_immunities,
    'senses', v_c.senses,
    'languages', v_c.languages,
    'challenge_text', v_c.challenge || coalesce(' (' || to_char(v_c.xp, 'FM999,999,990') || ' XP)', ''),
    'legendary_per_round', v_c.legendary_per_round,
    'legendary_intro', v_c.legendary_intro,
    'lair_title', v_c.lair_title,
    'lair_intro', v_c.lair_intro,
    'rumor_title', v_c.rumor_title,
    'rumor_intro', v_c.rumor_intro,
    'rumors', v_c.rumors,
    'rumor_note', v_c.rumor_note,
    'gm_tip', v_c.gm_tip,
    -- The character-scale numbers the table uses. Difficulties come from rpg_difficulty, never computed here.
    'table', jsonb_build_object(
        'attack_skill', v_c.attack_skill,
        'defense_skill', v_c.defense_skill,
        'difficulty_to_hit', CASE WHEN v_c.defense_skill IS NULL THEN NULL ELSE public.rpg_difficulty(v_c.defense_skill, true) END,
        'difficulty_to_hit_still', CASE WHEN v_c.defense_skill IS NULL THEN NULL ELSE public.rpg_difficulty(v_c.defense_skill, false) END,
        'vitality', v_c.vitality,
        'strength_skill', v_c.strength_skill,
        'will_skill', v_c.will_skill,
        'stealth_skill', v_c.stealth_skill,
        'awareness_skill', v_c.awareness_skill,
        'will_multiplier', public.rpg_setting('opponent_will_multiplier'),
        'attacks_roll_against', (SELECT d.name FROM public.rpg_stat_definitions d
                                  WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND d.key = 'EE')),
    -- How a character made from this card is rolled: its parent card, and its whole blueprint (its own entries and
    -- what it takes from the cards above it), each as low and high (the same number when fixed). The standard roll
    -- for anything left out is d(die) ÷ divisor, rounded up.
    'template', jsonb_build_object(
        'parent_key', v_c.parent_key,
        'parent_name', (SELECT p.name FROM public.rpg_creatures p WHERE p.agency_id = v_c.agency_id AND p.key = v_c.parent_key),
        'entries', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'key', d.key, 'name', d.name,
                        'low',  CASE jsonb_typeof(b.value) WHEN 'array' THEN (b.value ->> 0)::numeric ELSE (b.value #>> '{}')::numeric END,
                        'high', CASE jsonb_typeof(b.value) WHEN 'array' THEN (b.value ->> 1)::numeric ELSE (b.value #>> '{}')::numeric END,
                        'inherited', NOT (v_c.blueprint ? d.key))
                      ORDER BY d.sort_order, d.key), '[]'::jsonb)
                      FROM jsonb_each(public.rpg_template_blueprint(v_c.key)) AS b
                      JOIN public.rpg_template_stat_defs(v_c.key) d ON d.key = b.key),
        'die', public.rpg_setting('strength_roll_max'),
        'divisor', public.rpg_setting('strength_roll_divisor')),
    'actions', (SELECT coalesce(jsonb_agg(jsonb_build_object(
        'id', a.id, 'kind', a.kind, 'name', a.name,
        'heading', a.name
            || CASE WHEN a.recharge_min IS NULL THEN '' WHEN a.recharge_min < 6 THEN ' (Recharge ' || a.recharge_min || '–6)' ELSE ' (Recharge 6)' END
            || CASE WHEN a.kind = 'legendary' AND a.legendary_cost > 1 THEN ' (Costs ' || a.legendary_cost || ' Actions)' ELSE '' END,
        'description', a.description,
        'to_hit', a.to_hit, 'reach_ft', a.reach_ft, 'range_text', a.range_text,
        'save_dc', a.save_dc, 'save_ability', a.save_ability,
        'save_ability_name', CASE a.save_ability WHEN 'str' THEN 'Strength' WHEN 'dex' THEN 'Dexterity' WHEN 'con' THEN 'Constitution'
                               WHEN 'int' THEN 'Intelligence' WHEN 'wis' THEN 'Wisdom' WHEN 'cha' THEN 'Charisma' END,
        'skill', a.skill, 'against', a.against,
        'against_name', (SELECT d.name FROM public.rpg_stat_definitions d
                          WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND d.key = a.against),
        'table_note', a.table_note,
        'recharge_min', a.recharge_min, 'legendary_cost', a.legendary_cost, 'makes_attacks', a.makes_attacks)
      ORDER BY array_position(ARRAY['trait','action','bonus_action','reaction','legendary','lair'], a.kind), a.sort_order), '[]'::jsonb)
      FROM public.rpg_creature_actions a WHERE a.creature_id = v_c.id));
END;
$function$;

-- 11. Until NPCs are spawned from cards (unification step 3), only a card with fight numbers can join a fight as a
--     creature. Human has none, so it stays off the Add creature list and rpg_session_add refuses it.
DO $m$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_def := pg_get_functiondef('public.rpg_session_state(uuid)'::regprocedure);
  v_old := 'FROM public.rpg_creatures c WHERE c.is_active)) END);';
  v_new := 'FROM public.rpg_creatures c WHERE c.is_active AND coalesce(c.vitality, c.hit_points) IS NOT NULL)) END);';
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'rpg_session_state: the Add creature list anchor is not there exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);

  v_def := pg_get_functiondef('public.rpg_session_add(uuid,uuid,uuid)'::regprocedure);
  v_old := 'IF NOT FOUND THEN RAISE EXCEPTION ''creature not found''; END IF;';
  v_new := v_old || E'\n    IF NOT EXISTS (SELECT 1 FROM public.rpg_creatures WHERE id = p_creature_id AND coalesce(vitality, hit_points) IS NOT NULL) THEN\n      RAISE EXCEPTION ''% has no fight numbers yet'', v_name;\n    END IF;';
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'rpg_session_add: the creature check anchor is not there exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $m$;

-- 12. The rule card says where a character's numbers come from now. The first paragraph stays word for word.
UPDATE public.rpg_rules
   SET body = body || E'\n\n' || 'Every character is made from a card. Player characters come from the Human card, which rolls exactly as above. Another card can give a range instead: Strength 8 to 12 rolls one of 8, 9, 10, 11 or 12, each as likely. Or it can fix a number, the same every time, the way a boss is made. Anything a card leaves out rolls as above. A card can sit under a parent card and take the parent''s numbers for whatever it leaves out. A card can also carry a skill only its own characters have, such as a claw skill for clawed creatures.'
 WHERE key = 'strength_roll' AND body NOT LIKE '%Every character is made from a card.%';

-- 13. The helpers are inside jobs: no login calls them directly (a card's hidden numbers stay hidden).
REVOKE ALL ON FUNCTION public.rpg_template_chain(text), public.rpg_template_blueprint(text),
  public.rpg_template_stat_defs(text), public.rpg_roll_inputs(text), public.rpg_creatures_template_check()
  FROM PUBLIC, anon, authenticated;

-- 14. Guards: nothing still calls the generator without a card, one rpg_new_character, and it kept its grant.
DO $g$
DECLARE
  v_left text;
BEGIN
  SELECT string_agg(p.proname, ', ') INTO v_left
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prokind = 'f' AND pg_get_functiondef(p.oid) ~ 'rpg_roll_inputs\(\s*\)';
  IF v_left IS NOT NULL THEN RAISE EXCEPTION 'still calling rpg_roll_inputs() without a card: %', v_left; END IF;
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = 'rpg_new_character') <> 1 THEN
    RAISE EXCEPTION 'rpg_new_character must have exactly one version';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.rpg_new_character(text, uuid, boolean, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'rpg_new_character lost its grant';
  END IF;
  IF has_function_privilege('authenticated', 'public.rpg_template_blueprint(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'rpg_template_blueprint must not be callable by a login';
  END IF;
END $g$;

NOTIFY pgrst, 'reload schema';
