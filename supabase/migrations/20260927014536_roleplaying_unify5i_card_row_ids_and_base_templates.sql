-- Roleplaying unify5i: characters and card-only stats point at their card by row id (template_id), like a card's
-- parent (Peter 2026-09-27: no typed keys), and the basic templates: Creature (every living card is made from it and
-- holds Spirit, Mind and every skill) and Object (Body only: Strength, Agility, Toughness and what is figured from
-- them, Physical Vitality and Integrity). Human and the five creature cards now sit under Creature; nothing they roll
-- changes, since Creature's blueprint is empty.

ALTER TABLE public.rpg_characters ADD COLUMN IF NOT EXISTS template_id uuid REFERENCES public.rpg_creatures(id);
ALTER TABLE public.rpg_stat_definitions ADD COLUMN IF NOT EXISTS template_id uuid REFERENCES public.rpg_creatures(id);
UPDATE public.rpg_characters ch SET template_id = c.id FROM public.rpg_creatures c
 WHERE c.agency_id = ch.agency_id AND c.key = ch.template_key;
UPDATE public.rpg_stat_definitions d SET template_id = c.id FROM public.rpg_creatures c
 WHERE d.template_key IS NOT NULL AND c.agency_id = d.agency_id AND c.key = d.template_key;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM public.rpg_characters WHERE template_id IS NULL) THEN RAISE EXCEPTION 'a character has no card'; END IF;
  IF EXISTS (SELECT 1 FROM public.rpg_stat_definitions WHERE template_key IS NOT NULL AND template_id IS NULL) THEN RAISE EXCEPTION 'a stat lost its card'; END IF;
END $$;
ALTER TABLE public.rpg_characters ALTER COLUMN template_id SET NOT NULL;

DROP FUNCTION public.rpg_new_character(text, uuid, boolean, text);
DROP FUNCTION public.rpg_apply_experience(uuid, text);
DROP FUNCTION public.rpg_roll_inputs(text);
DROP FUNCTION public.rpg_template_stat_defs(text);
DROP FUNCTION public.rpg_template_blueprint(text);
DROP FUNCTION public.rpg_template_chain(text);

CREATE FUNCTION public.rpg_template_chain(p_card uuid)
 RETURNS uuid[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A card and every card above it, nearest first, as row ids, walking each card's parent_id. A Harrier card made from
-- Creature gives {Harrier, Creature}; no card gives {}. The one place that says what a card is made of. Stops at ten
-- levels and never visits a card twice.
WITH RECURSIVE up AS (
  SELECT c.id, c.parent_id, 1 AS depth, ARRAY[c.id] AS path
    FROM public.rpg_creatures c
   WHERE c.id = p_card
  UNION ALL
  SELECT c.id, c.parent_id, up.depth + 1, up.path || c.id
    FROM up
    JOIN public.rpg_creatures c ON c.id = up.parent_id
   WHERE up.depth < 10 AND NOT c.id = ANY (up.path)
)
SELECT coalesce(array_agg(id ORDER BY depth), '{}'::uuid[]) FROM up;
$function$;

CREATE FUNCTION public.rpg_template_blueprint(p_card uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A card's whole blueprint, with what it takes from the cards above it: the parent's entries first, the card's own win.
-- Wolf {"ST": 12, "AG": {"divisor": 5}} above a Grey Wolf {"ST": 11} gives {"ST": 11, "AG": {"divisor": 5}}.
SELECT coalesce(jsonb_object_agg(e.key, e.value ORDER BY t.depth DESC), '{}'::jsonb)
  FROM unnest(public.rpg_template_chain(p_card)) WITH ORDINALITY AS t(id, depth)
  JOIN public.rpg_creatures c ON c.id = t.id
 CROSS JOIN LATERAL jsonb_each(c.blueprint) AS e;
$function$;

CREATE FUNCTION public.rpg_template_stat_defs(p_card uuid)
 RETURNS SETOF public.rpg_stat_definitions
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The stats a character made from this card has: every shared one (template_id null: the Body traits and what is
-- figured only from them) plus the ones that belong to the card or a card above it. Spirit, Mind and the skills
-- belong to Creature, so every living card has them and an Object has none; the Bramblemaw's Claw belongs to it alone.
-- The sheet, the generator and the checks all ask this.
SELECT d.*
  FROM public.rpg_stat_definitions d
 WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND (d.template_id IS NULL OR d.template_id = ANY (public.rpg_template_chain(p_card)));
$function$;

CREATE FUNCTION public.rpg_roll_inputs(p_card uuid)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A new character's inputs from the card it is made from. Every rolled stat follows the one rolling rule: a d100
-- (1 to 100) divided by its divider, rounded up. The standard divider is the strength_roll_divisor setting (10: a 47
-- makes 5, so 1 to 10). A card may give a trait its own divider, never under 1 ({"ST": {"divisor": 2}}: a 47 makes 24,
-- so 1 to 50), or set a number, the same every time, the way a boss is made. A fixed stat starts at its default
-- (Sword of the Spirit 1) unless the card sets it. A card's experience is spent afterwards by rpg_apply_experience.
SELECT public.require_login('family');
  SELECT coalesce(jsonb_object_agg(d.key,
           CASE
             WHEN jsonb_typeof(b.bp -> d.key) = 'number' THEN (b.bp ->> d.key)::numeric
             WHEN d.kind = 'rolled' THEN
               ceil((floor(random() * public.rpg_setting('strength_roll_max')) + 1)
                    / greatest(coalesce((b.bp -> d.key ->> 'divisor')::numeric, public.rpg_setting('strength_roll_divisor')), 1))
             ELSE d.default_value
           END), '{}'::jsonb)
    FROM public.rpg_template_stat_defs(p_card) d
   CROSS JOIN (SELECT public.rpg_template_blueprint(p_card) AS bp) b
   WHERE d.kind IN ('rolled','fixed');
$function$;

CREATE FUNCTION public.rpg_apply_experience(p_character_id uuid, p_card uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- For every entry with "points" in the card's blueprint (its own and its parents'), in sheet order (the root pair,
-- then the fruits, then Mind and Body, then skills, so each sees the final numbers of what it is built on):
--   a Spirit trait climbs the level ladder from its rolled side and the levels it earns go through the pair rules
--   (rpg_move_trait, not strict): a Gloam Wisp's Hatred 4 with 80,000 points climbs to 9, unless its Fascination with
--   Evil is lower, in which case it stops there;
--   any other stat starts over (a reroll makes the character again) and spends the points from its value on the fresh
--   sheet (rpg_add_skill_points).
-- Used by rpg_new_character and rpg_reroll_character.
DECLARE
  v_key   text;
  v_pts   numeric;
  v_pair  text;
  v_now   numeric;
  v_level integer;
BEGIN
  FOR v_key, v_pts, v_pair IN
    SELECT b.key, (b.value ->> 'points')::numeric, d.pair_key
      FROM jsonb_each(public.rpg_template_blueprint(p_card)) b
      LEFT JOIN public.rpg_stat_definitions d ON d.key = b.key AND d.agency_id = '126794dd-25ff-47d2-a436-724499733365'
     WHERE jsonb_typeof(b.value) = 'object' AND jsonb_typeof(b.value -> 'points') = 'number'
     ORDER BY d.sort_order NULLS LAST, b.key
  LOOP
    IF v_pair IS NOT NULL THEN
      SELECT coalesce((c.inputs ->> v_key)::numeric, 0) INTO v_now FROM public.rpg_characters c WHERE c.id = p_character_id;
      SELECT l.level INTO v_level FROM public.rpg_climb_levels(v_now::integer, v_pts) l;
      PERFORM public.rpg_move_trait(p_character_id, v_key, v_level - v_now::integer, false);
    ELSE
      DELETE FROM public.rpg_character_skills WHERE character_id = p_character_id AND stat_key = v_key;
      SELECT (s ->> 'value')::numeric INTO v_now
        FROM jsonb_array_elements(public.rpg_sheet(p_character_id) -> 'stats') s WHERE s ->> 'key' = v_key;
      PERFORM public.rpg_add_skill_points(p_character_id, v_key, v_pts, coalesce(v_now, 0));
    END IF;
  END LOOP;
END;
$function$;

CREATE FUNCTION public.rpg_new_character(p_name text, p_kid_id uuid DEFAULT NULL::uuid, p_is_npc boolean DEFAULT false, p_card uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Makes a character from a card, named by its row id (none = the Human card). Its inputs come from
-- rpg_roll_inputs(card): a Human rolls every trait d100 ÷ 10, rounded up (a 47 makes 5); another card rolls with its
-- own dividers and set numbers, then its experience is spent by rpg_apply_experience (a Thornfield Boar rolls
-- Toughness d100 ÷ 10, so a 47 makes 5, and its card's growth takes that to 16).
-- Anyone may make a Human (the players' own card). Players may use another card once it has been shown to them;
-- the game master may use any card on the list.
DECLARE
  v_id      uuid;
  v_n       integer;
  v_card    uuid;
  v_key     text;
  v_active  boolean;
  v_shown   boolean;
  v_palette text[] := ARRAY['#737A59','#A88B5F','#5E7A77','#6E5B7A','#A87A75','#255C99','#2E8B57','#D4A017'];
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF coalesce(btrim(p_name), '') = '' THEN RAISE EXCEPTION 'name required'; END IF;
  SELECT id, key, is_active, shown_to_players INTO v_card, v_key, v_active, v_shown
    FROM public.rpg_creatures
   WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
     AND CASE WHEN p_card IS NULL THEN key = 'human' ELSE id = p_card END;
  IF v_card IS NULL OR NOT v_active THEN RAISE EXCEPTION 'that card is not on the list'; END IF;
  IF v_key <> 'human' AND NOT v_shown AND NOT public.family_is_parent() THEN
    RAISE EXCEPTION 'that card has not been shown to players';
  END IF;
  SELECT count(*) INTO v_n FROM public.rpg_characters WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';
  INSERT INTO public.rpg_characters (name, kid_id, is_npc, template_id, inputs, color)
  VALUES (btrim(p_name), p_kid_id, coalesce(p_is_npc, false), v_card, public.rpg_roll_inputs(v_card), v_palette[(v_n % 8) + 1])
  RETURNING id INTO v_id;
  PERFORM public.rpg_apply_experience(v_id, v_card);
  RETURN v_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpg_template_chain(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_template_blueprint(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_template_stat_defs(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_roll_inputs(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_apply_experience(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpg_new_character(text, uuid, boolean, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpg_new_character(text, uuid, boolean, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpg_template_chain(uuid), public.rpg_template_blueprint(uuid), public.rpg_template_stat_defs(uuid),
  public.rpg_roll_inputs(uuid), public.rpg_apply_experience(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.rpg_reroll_character(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The character made again from its own card: a Human rolls every trait again; a card's set numbers come back the
-- same; a card's experience is spent again from the new roll. A player may re-roll only a character that has not
-- played yet.
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
  UPDATE public.rpg_characters SET inputs = public.rpg_roll_inputs(template_id) WHERE id = p_character_id
  RETURNING template_id INTO v_card;
  PERFORM public.rpg_apply_experience(p_character_id, v_card);
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
   CROSS JOIN LATERAL public.rpg_template_stat_defs(c.template_id) d
   WHERE c.id = p_character_id AND d.key = p_key;
  IF v_kind IS NULL THEN RAISE EXCEPTION 'this character does not have that stat'; END IF;
  IF v_kind NOT IN ('rolled','fixed') THEN RAISE EXCEPTION 'that stat is calculated, not set'; END IF;
  UPDATE public.rpg_characters SET inputs = inputs || jsonb_build_object(p_key, p_value) WHERE id = p_character_id;
  RETURN public.rpg_sheet(p_character_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_move_trait(p_character_id uuid, p_key text, p_delta integer, p_strict boolean)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Moves one rolled or fixed trait by p_delta and returns how far it actually moved. For a paired Spirit trait: growth
-- (+) is capped by the root on that side (Connection with God for a good side, Fascination with Evil for an evil side;
-- the root itself has no cap) and pulls the opposite side down by as much as actually grew; a loss (−) lowers this side
-- only, never below 0. Love 7 / Hatred 2, Hatred +3 → Hatred 5, Love 4. Love 4 with Connection 3: Love +1 is refused
-- when p_strict (an event), and simply does not grow when not (a card's growth). Body and Mind traits move plainly.
-- Callers: rpg_adjust_trait (events) and rpg_apply_experience (a card's growth). Not callable by a login.
DECLARE
  v_c        record;
  v_d        record;
  v_now      numeric;
  v_new      numeric;
  v_grew     numeric;
  v_partner  numeric;
  v_cap      numeric;
  v_root     text;
  v_root_key text;
BEGIN
  IF coalesce(p_delta, 0) = 0 THEN RETURN 0; END IF;
  SELECT * INTO v_c FROM public.rpg_characters WHERE id = p_character_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'character not found'; END IF;
  SELECT d.* INTO v_d FROM public.rpg_template_stat_defs(v_c.template_id) d WHERE d.key = p_key;
  IF NOT FOUND THEN RAISE EXCEPTION 'this character does not have that stat'; END IF;
  IF v_d.kind NOT IN ('rolled', 'fixed') THEN RAISE EXCEPTION 'that stat is calculated, not set'; END IF;
  v_now := coalesce((v_c.inputs->>p_key)::numeric, v_d.default_value);
  v_new := greatest(v_now + p_delta, 0);
  IF p_delta > 0 AND v_d.pair_key IS NOT NULL AND p_key NOT IN ('CG', 'FE') THEN
    v_root_key := CASE v_d.side WHEN 'good' THEN 'CG' ELSE 'FE' END;
    v_cap := greatest(coalesce((v_c.inputs->>v_root_key)::numeric, 0)
                      - coalesce((v_c.inputs->>(CASE v_root_key WHEN 'CG' THEN 'FE' ELSE 'CG' END))::numeric, 0), 0);
    IF v_new > v_cap THEN
      IF v_now >= v_cap THEN
        IF p_strict THEN
          SELECT name INTO v_root FROM public.rpg_stat_definitions WHERE agency_id = v_c.agency_id AND key = v_root_key;
          RAISE EXCEPTION '% cannot grow past % (%): grow that first', v_d.name, v_root, v_cap;
        END IF;
        RETURN 0;
      END IF;
      v_new := v_cap;
    END IF;
  END IF;
  v_grew := v_new - v_now;
  UPDATE public.rpg_characters SET inputs = inputs || jsonb_build_object(p_key, v_new) WHERE id = p_character_id;
  IF v_grew > 0 AND v_d.pair_key IS NOT NULL THEN
    v_partner := greatest(coalesce((v_c.inputs->>v_d.pair_key)::numeric, 0) - v_grew, 0);
    UPDATE public.rpg_characters SET inputs = inputs || jsonb_build_object(v_d.pair_key, v_partner) WHERE id = p_character_id;
  END IF;
  RETURN v_new - v_now;
END;
$function$;

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

CREATE OR REPLACE FUNCTION public.rpg_creature_actions_skill_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- An action can only use stats its card has: a shared one, or one that belongs to the card or a card above it
-- (rpg_template_stat_defs). That holds for the skill it rolls (skill_key), the skill a contest rolls, and every stat
-- an effect gives a bonus to. The Bramblemaw's Claw may roll Claw; the Boar's Gore may not. Sink Into Soil may give
-- Evade Enemy (EE) + 4; a bonus to "defense" is refused, because no sheet has a stat by that name.
DECLARE v_card uuid; v_name text; v_k text;
BEGIN
  SELECT c.id, c.name INTO v_card, v_name FROM public.rpg_creatures c WHERE c.id = NEW.creature_id;
  IF NEW.skill_key IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.rpg_template_stat_defs(v_card) d WHERE d.key = NEW.skill_key) THEN
    RAISE EXCEPTION '% on the % card cannot roll %: the card does not have that skill', NEW.name, v_name, NEW.skill_key;
  END IF;
  IF NEW.effect->'contest'->>'skill_key' IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.rpg_template_stat_defs(v_card) d WHERE d.key = NEW.effect->'contest'->>'skill_key') THEN
    RAISE EXCEPTION '% on the % card cannot contest with %: the card does not have that stat', NEW.name, v_name, NEW.effect->'contest'->>'skill_key';
  END IF;
  IF jsonb_typeof(NEW.effect->'apply'->'bonus') = 'object' THEN
    FOR v_k IN SELECT jsonb_object_keys(NEW.effect->'apply'->'bonus') LOOP
      IF NOT EXISTS (SELECT 1 FROM public.rpg_template_stat_defs(v_card) d WHERE d.key = v_k) THEN
        RAISE EXCEPTION '% on the % card gives a bonus to %, which the card does not have', NEW.name, v_name, v_k;
      END IF;
    END LOOP;
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_add(p_session_id uuid, p_character_id uuid DEFAULT NULL::uuid, p_creature_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Adds one character, or one creature made fresh from its card, to a fight at its Agility place: ahead of the first
-- one in line with lower Agility, so higher Agility acts first and a tie goes after whoever joined first. The game
-- master's own moves stay. A creature is made the way any character is made (rpg_new_character from its card, as a
-- non-player character), kept for this fight only (session_id) and left off the players' lists. So two Ashwing
-- Harriers are two different rolls (Physical Vitality 40 to 50), while a boss card like the Bramblemaw comes out the
-- same every time. The Bramblemaw (Agility 7) lands ahead of Karen (Agility 1). A second one is named "Bramblemaw 2".
DECLARE v_s record; v_name text; v_card uuid; v_leg integer := 0; v_n integer; v_id uuid; v_char uuid := p_character_id; v_ag numeric; v_pos integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master adds to a fight'; END IF;
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
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, actor_id, text)
  VALUES (v_s.agency_id, p_session_id, v_s.round, 'join', v_id, v_name || ' joins the fight (Agility ' || trim_scale(v_ag) || ').');
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = p_session_id;
  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_creature_card(p_creature_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One creature card, built only from its record. Players get it once it is shown to them, and then only its names,
-- haunts, epigraph, lore and picture. The game master also gets how a creature is made from the card (template:
-- its parent and each blueprint entry) and each action's text with one line of what it does (rpg_action_text, the
-- same line the fight screen shows), the lair and legendary text, the rumor table and the tip.
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
    'epigraph', v_c.epigraph, 'lore', v_c.lore, 'image_path', v_c.image_path);
  IF NOT v_gm THEN RETURN v_card; END IF;

  RETURN v_card || jsonb_build_object(
    'shown_to_players', v_c.shown_to_players,
    'source_manual_id', v_c.source_manual_id,
    'legendary_per_round', v_c.legendary_per_round,
    'legendary_intro', v_c.legendary_intro,
    'lair_title', v_c.lair_title,
    'lair_intro', v_c.lair_intro,
    'rumor_title', v_c.rumor_title,
    'rumor_intro', v_c.rumor_intro,
    'rumors', v_c.rumors,
    'rumor_note', v_c.rumor_note,
    'gm_tip', v_c.gm_tip,
    -- Its parent card, and its whole blueprint (its own entries and what it takes from the cards above it): a set
    -- number (a boss), a divider the roll lands under (top), or experience points spent up the level ladder (from_1
    -- and from_top: where those points take a roll of 1 and a roll at the top). Anything left out rolls the standard way.
    'template', jsonb_build_object(
        'parent_id', v_c.parent_id,
        'parent_name', (SELECT p.name FROM public.rpg_creatures p WHERE p.id = v_c.parent_id),
        'entries', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'key', d.key, 'name', d.name,
                        'fixed',   CASE WHEN jsonb_typeof(b.value) = 'number' THEN (b.value #>> '{}')::numeric END,
                        'divisor', CASE WHEN jsonb_typeof(b.value) = 'object' THEN (b.value ->> 'divisor')::numeric END,
                        'top',     CASE WHEN jsonb_typeof(b.value) = 'object' AND (b.value ? 'divisor') THEN ceil(public.rpg_setting('strength_roll_max') / greatest((b.value ->> 'divisor')::numeric, 1)) END,
                        'points',  CASE WHEN jsonb_typeof(b.value) = 'object' THEN (b.value ->> 'points')::numeric END,
                        'from_1',  CASE WHEN jsonb_typeof(b.value) = 'object' THEN (SELECT c.level FROM public.rpg_climb_levels(1, (b.value ->> 'points')::numeric) c) END,
                        'from_top', CASE WHEN jsonb_typeof(b.value) = 'object' AND (b.value ? 'points') THEN (SELECT c.level FROM public.rpg_climb_levels(CASE WHEN b.value ? 'divisor' THEN ceil(public.rpg_setting('strength_roll_max') / greatest((b.value ->> 'divisor')::numeric, 1)) ELSE ceil(public.rpg_setting('strength_roll_max') / public.rpg_setting('strength_roll_divisor')) END::integer, (b.value ->> 'points')::numeric) c) END,
                        'inherited', NOT (v_c.blueprint ? d.key))
                      ORDER BY d.sort_order, d.key), '[]'::jsonb)
                      FROM jsonb_each(public.rpg_template_blueprint(v_c.id)) AS b
                      JOIN public.rpg_template_stat_defs(v_c.id) d ON d.key = b.key)),
    'actions', (SELECT coalesce(jsonb_agg(jsonb_build_object(
        'id', a.id, 'kind', a.kind, 'name', a.name,
        'heading', a.name
            || CASE WHEN a.kind = 'legendary' AND a.legendary_cost > 1 THEN ' (Costs ' || a.legendary_cost || ' Actions)' ELSE '' END,
        'description', a.description,
        'line', public.rpg_action_text(a.id))
      ORDER BY array_position(ARRAY['trait','action','bonus_action','reaction','legendary','lair'], a.kind), a.sort_order), '[]'::jsonb)
      FROM public.rpg_creature_actions a WHERE a.creature_id = v_c.id));
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_creatures_template_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Parent: a card's parent is another card's row id (parent_id), or none for a top card; it can never end up above
-- itself (Wolf under Grey Wolf under Wolf is refused).
-- Blueprint: each entry is a stat key and either a whole number for a rolled or fixed stat, set the same every time
-- ({"ST": 33}, the way a boss is made), or an object with "divisor" (a rolled stat: d100 ÷ d rounded up, d at least 1,
-- so ÷ 2 lands 1 to 50) and/or "points" (experience spent up the level ladder from the roll: a skill, or a trait
-- growing into its kind's size; a Spirit trait grows by the pair rules in rpg_move_trait).
-- A calculated stat that cannot be trained (Physical Vitality) comes from the sheet, never the blueprint.
DECLARE
  v_key       text;
  v_val       jsonb;
  v_kind      text;
  v_trainable boolean;
  v_n         numeric;
  v_extra     text;
  v_pname     text;
BEGIN
  IF NEW.parent_id IS NOT NULL THEN
    SELECT p.name INTO v_pname FROM public.rpg_creatures p WHERE p.id = NEW.parent_id;
    IF v_pname IS NULL THEN
      RAISE EXCEPTION '% cannot be made from that card: it is not on the list', NEW.name;
    END IF;
    IF NEW.id = ANY (public.rpg_template_chain(NEW.parent_id)) THEN
      RAISE EXCEPTION '% cannot be made from %: it would sit above itself', NEW.name, v_pname;
    END IF;
  END IF;
  IF NEW.blueprint IS NULL OR jsonb_typeof(NEW.blueprint) <> 'object' THEN
    RAISE EXCEPTION '%: a blueprint lists stats and their numbers', NEW.name;
  END IF;
  FOR v_key, v_val IN SELECT b.key, b.value FROM jsonb_each(NEW.blueprint) AS b LOOP
    v_kind := NULL;
    SELECT d.kind, coalesce(d.trainable, false) INTO v_kind, v_trainable
      FROM public.rpg_template_stat_defs(NEW.parent_id) d WHERE d.key = v_key;
    IF v_kind IS NULL THEN
      SELECT d.kind, coalesce(d.trainable, false) INTO v_kind, v_trainable FROM public.rpg_stat_definitions d
       WHERE d.template_id = NEW.id AND d.key = v_key;
    END IF;
    IF v_kind IS NULL THEN
      RAISE EXCEPTION '% blueprint: % is not a stat this card has', NEW.name, v_key;
    END IF;
    IF jsonb_typeof(v_val) = 'number' THEN
      IF v_kind NOT IN ('rolled', 'fixed') THEN
        RAISE EXCEPTION '% blueprint: % is calculated from other stats, so it cannot be set', NEW.name, v_key;
      END IF;
      v_n := (v_val #>> '{}')::numeric;
      IF v_n < 0 OR v_n <> trunc(v_n) THEN
        RAISE EXCEPTION '% blueprint: % must be a whole number, 0 or more (got %)', NEW.name, v_key, v_val;
      END IF;
    ELSIF jsonb_typeof(v_val) = 'object' THEN
      SELECT string_agg(k, ', ') INTO v_extra FROM jsonb_object_keys(v_val) k WHERE k NOT IN ('divisor', 'points');
      IF v_extra IS NOT NULL OR (SELECT count(*) FROM jsonb_object_keys(v_val)) = 0 THEN
        RAISE EXCEPTION '% blueprint: % takes a set number, {"divisor": d} or {"points": n} (got %)', NEW.name, v_key, v_val;
      END IF;
      IF v_val ? 'divisor' THEN
        IF jsonb_typeof(v_val -> 'divisor') IS DISTINCT FROM 'number' THEN
          RAISE EXCEPTION '% blueprint: % divider must be a number (got %)', NEW.name, v_key, v_val;
        END IF;
        IF v_kind <> 'rolled' THEN
          RAISE EXCEPTION '% blueprint: % is not rolled, so it cannot take a divider', NEW.name, v_key;
        END IF;
        IF (v_val ->> 'divisor')::numeric < 1 THEN
          RAISE EXCEPTION '% blueprint: % divider can never be under 1 (got %)', NEW.name, v_key, v_val;
        END IF;
      END IF;
      IF v_val ? 'points' THEN
        IF jsonb_typeof(v_val -> 'points') IS DISTINCT FROM 'number' THEN
          RAISE EXCEPTION '% blueprint: % experience must be a number (got %)', NEW.name, v_key, v_val;
        END IF;
        IF NOT v_trainable AND v_kind <> 'rolled' THEN
          RAISE EXCEPTION '% blueprint: % cannot take experience (a skill or a rolled trait can)', NEW.name, v_key;
        END IF;
        IF (v_val ->> 'points')::numeric < 0 THEN
          RAISE EXCEPTION '% blueprint: % experience must be 0 or more (got %)', NEW.name, v_key, v_val;
        END IF;
      END IF;
    ELSE
      RAISE EXCEPTION '% blueprint: % takes a set number, {"divisor": d} or {"points": n} (got %)', NEW.name, v_key, v_val;
    END IF;
  END LOOP;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_creatures_delete_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A card is deleted only when nothing still depends on it: no card made from it, no character made from it (fight
-- creatures included) and none of its own skills left. Otherwise the plain reason, never a raw key error.
DECLARE
  v_kids   text;
  v_chars  integer;
  v_skills text;
BEGIN
  SELECT string_agg(c.name, ', ' ORDER BY c.name) INTO v_kids
    FROM public.rpg_creatures c WHERE c.parent_id = OLD.id;
  SELECT count(*) INTO v_chars
    FROM public.rpg_characters ch WHERE ch.template_id = OLD.id;
  SELECT string_agg(d.name, ', ' ORDER BY d.sort_order, d.name) INTO v_skills
    FROM public.rpg_stat_definitions d WHERE d.template_id = OLD.id;
  IF v_kids IS NOT NULL OR v_chars > 0 OR v_skills IS NOT NULL THEN
    RAISE EXCEPTION '% cannot be deleted yet. Still made from it: %', OLD.name,
      concat_ws('; ', 'cards ' || v_kids,
                CASE WHEN v_chars > 0 THEN v_chars || CASE WHEN v_chars = 1 THEN ' character' ELSE ' characters' END END,
                'its own skills ' || v_skills);
  END IF;
  RETURN OLD;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_state(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Everything the Play tab shows for one fight in one read: the fight, everyone in turn order with their effects and
-- whether they can act, a character's pending check (Frightened → Courage against 8, needs 54), the last 60 log
-- lines with their outcome keys. A creature's numbers come from the sheet it was made with; players get creatures
-- without numbers and no game-master lists. The game master gets each creature's stats (its own card's skills
-- first) and, on every action, the number it rolls (the Bramblemaw's Claw: 10) and one line of what it does
-- (rpg_action_text, the same line the creature card shows).
DECLARE
  v_gm boolean := public.family_is_parent();
  v_s record; v_p record; v_sheet jsonb; v_c record; v_vit jsonb; v_item jsonb; v_parts jsonb := '[]'::jsonb; v_vals jsonb;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  FOR v_p IN SELECT * FROM public.rpg_session_participants WHERE session_id = p_session_id ORDER BY turn_order, created_at LOOP
    IF v_p.creature_id IS NULL THEN
      v_sheet := public.rpg_sheet(v_p.character_id, public.rpg_setting('default_difficulty'));
      v_item := jsonb_build_object('kind', 'character', 'character_id', v_p.character_id, 'color', v_sheet->'color',
        'vitality_max', (v_sheet->>'vitality_max')::integer,
        'vitality_left', greatest((v_sheet->>'vitality_left')::integer, 0),
        'agility', (SELECT s->'value' FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = 'AG'),
        'weapons', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', s->>'key', 'name', s->>'name', 'value', s->'value', 'beats', d.beats, 'energy_cost', d.energy_cost, 'energy_type', d.energy_type)
                                    ORDER BY (s->>'value')::numeric DESC, s->>'name'), '[]'::jsonb)
                      FROM jsonb_array_elements(v_sheet->'stats') s
                      JOIN public.rpg_stat_definitions d ON d.key = s->>'key' AND d.is_attack),
        'pending_check', (SELECT jsonb_build_object('name', e->>'name', 'stat', e->>'check_stat', 'stat_name', d.name,
                            'difficulty', (e->>'check_difficulty')::numeric,
                            'skill', (SELECT s->'value' FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = e->>'check_stat'),
                            'needed', public.rpg_needed((SELECT (s->>'value')::numeric FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = e->>'check_stat'),
                                                        (e->>'check_difficulty')::numeric)->'needed')
                            FROM jsonb_array_elements(v_p.effects) e JOIN public.rpg_stat_definitions d ON d.key = e->>'check_stat'
                           WHERE e->>'clear' = 'check' AND (e->>'checked_round')::integer IS DISTINCT FROM v_s.round LIMIT 1));
    ELSE
      SELECT * INTO v_c FROM public.rpg_creatures WHERE id = v_p.creature_id;
      v_vit := public.rpg_participant_vitality(v_p.id);
      v_item := jsonb_build_object('kind', 'creature', 'creature_id', v_p.creature_id, 'color', v_c.color,
        'vitality_share', CASE WHEN (v_vit->>'max')::numeric > 0 THEN round((v_vit->>'left')::numeric / (v_vit->>'max')::numeric, 3) END);
      IF v_gm THEN
        v_sheet := public.rpg_sheet(v_p.character_id, public.rpg_setting('default_difficulty'));
        v_vals := (SELECT coalesce(jsonb_object_agg(s->>'key', s->'value'), '{}'::jsonb) FROM jsonb_array_elements(v_sheet->'stats') s);
        v_item := v_item || jsonb_build_object(
          'vitality_max', (v_vit->>'max')::integer, 'vitality_left', (v_vit->>'left')::integer,
          'legendary_left', v_p.legendary_left, 'legendary_per_round', v_c.legendary_per_round, 'agility', v_vals->'AG',
          'skills', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', s->>'key', 'name', s->>'name', 'value', s->'value', 'own', d.template_id = v_p.creature_id)
                                     ORDER BY (d.template_id IS DISTINCT FROM v_p.creature_id), o), '[]'::jsonb)
                       FROM jsonb_array_elements(v_sheet->'stats') WITH ORDINALITY AS t(s, o)
                       JOIN public.rpg_stat_definitions d ON d.key = s->>'key'),
          'actions', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                          'id', a.id, 'name', a.name, 'kind', a.kind, 'skill_key', coalesce(u.skill_key, a.skill_key),
                          'skill', v_vals->coalesce(u.skill_key, a.skill_key),
                          'line', public.rpg_action_text(coalesce(u.id, a.id), (v_vals->>coalesce(u.skill_key, a.skill_key))::numeric),
                          'beats', a.beats, 'ready', a.ready,
                          'usable', (SELECT coalesce(sum(greatest(coalesce((e->>'count')::integer, 1), 1)), 0) FROM jsonb_array_elements(coalesce(a.makes_attacks, '[]'::jsonb)) e) <= 1)
                        ORDER BY CASE a.kind WHEN 'action' THEN 1 WHEN 'bonus_action' THEN 2 WHEN 'reaction' THEN 3 WHEN 'legendary' THEN 4 WHEN 'lair' THEN 5 ELSE 6 END, a.sort_order), '[]'::jsonb)
                        FROM (SELECT x.*, public.rpg_action_ready(v_p.id, x.id) AS ready FROM public.rpg_creature_actions x
                               WHERE x.creature_id = v_p.creature_id AND x.kind <> 'trait') a
                        LEFT JOIN public.rpg_creature_actions u ON u.creature_id = a.creature_id AND u.name = a.makes_attacks->0->>'action'
                              AND jsonb_array_length(coalesce(a.makes_attacks, '[]'::jsonb)) = 1));
      END IF;
    END IF;
    v_parts := v_parts || jsonb_build_array(jsonb_build_object('id', v_p.id, 'name', v_p.name, 'turn_order', v_p.turn_order,
                 'can_act', v_p.can_act, 'status_note', v_p.status_note, 'can_act_now', public.rpg_participant_can_act(v_p.id),
                 'effects', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', e->>'name', 'cannot_act', coalesce((e->>'cannot_act')::boolean, false), 'source', e->>'source')), '[]'::jsonb)
                               FROM jsonb_array_elements(v_p.effects) e),
                 'energy', public.rpg_participant_energy(v_p.id), 'is_current', coalesce(v_p.id = v_s.current_participant_id, false)) || v_item);
  END LOOP;
  RETURN jsonb_build_object(
    'session', jsonb_build_object('id', v_s.id, 'name', v_s.name, 'status', v_s.status, 'round', v_s.round,
                 'current_participant_id', v_s.current_participant_id, 'turn_attacks', v_s.turn_attacks,
                 'turn_beats', v_s.turn_beats, 'beats_per_turn', public.rpg_setting('beats_per_turn'), 'updated_at', v_s.updated_at),
    'is_gm', v_gm,
    'participants', v_parts,
    'events', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'round', e.round, 'kind', e.kind, 'outcome', e.outcome, 'text', e.text,
                                          'damage', e.damage, 'created_at', e.created_at) ORDER BY e.created_at DESC), '[]'::jsonb)
                 FROM (SELECT * FROM public.rpg_events WHERE session_id = p_session_id ORDER BY created_at DESC LIMIT 60) e),
    'available', CASE WHEN v_gm THEN jsonb_build_object(
        'characters', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) ORDER BY c.name), '[]'::jsonb)
                         FROM public.rpg_characters c
                        WHERE c.is_active AND c.session_id IS NULL
                          AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants p WHERE p.session_id = p_session_id AND p.character_id = c.id)),
        'creatures', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) ORDER BY c.sort_order, c.name), '[]'::jsonb)
                        FROM public.rpg_creatures c
                       WHERE c.is_active AND EXISTS (SELECT 1 FROM public.rpg_creature_actions a WHERE a.creature_id = c.id AND a.kind <> 'trait'))) END);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_rules_page(p_max_level integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The Rules tab in one read: the rule cards, every stat and how it is figured, the level costs and the settings.
-- A stat that belongs to one card (the Bramblemaw's Claw) carries that card's name, and players see it only once the
-- card has been shown to them. Stats every Human has (shared, or on Creature above it) carry no card name.
SELECT public.require_login('family');
  WITH gm AS (SELECT public.family_is_parent() AS is_gm),
       hc AS (SELECT coalesce((SELECT public.rpg_template_chain(c.id) FROM public.rpg_creatures c
                                WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.key = 'human'), '{}'::uuid[]) AS chain),
       names AS (
         SELECT coalesce(jsonb_object_agg(d.key, d.name), '{}'::jsonb) AS m
         FROM public.rpg_stat_definitions d
         WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365')
  SELECT jsonb_build_object(
    'is_gm', gm.is_gm,
    'rules', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                'key', r.key, 'title', r.title, 'body', r.body, 'source', r.source, 'section', r.section)
                ORDER BY r.sort_order, r.key), '[]'::jsonb)
              FROM public.rpg_rules r
              WHERE r.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
    'stats', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                'key', d.key, 'name', d.name, 'abbr', d.abbr, 'grp', d.grp, 'kind', d.kind,
                'trainable', d.trainable, 'default_value', d.default_value,
                'card_id', d.template_id, 'card_name', CASE WHEN d.template_id = ANY (hc.chain) THEN NULL ELSE c.name END,
                'formula_text', public.rpg_formula_text(d.formula, names.m))
                ORDER BY d.sort_order, d.key), '[]'::jsonb)
              FROM public.rpg_stat_definitions d CROSS JOIN names CROSS JOIN hc
              LEFT JOIN public.rpg_creatures c ON c.id = d.template_id
              WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365'
                AND (d.template_id IS NULL OR d.template_id = ANY (hc.chain) OR gm.is_gm OR (c.is_active AND c.shown_to_players))),
    'level_costs', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                      'level', l, 'next_level', l + 1, 'points', public.rpg_level_cost(l))
                      ORDER BY l), '[]'::jsonb)
                    FROM generate_series(0, greatest(coalesce(p_max_level, 30), 1)) AS l),
    'crit_chance', public.rpg_setting('crit_chance'),
    'default_difficulty', public.rpg_setting('default_difficulty'),
    'level_cost_multiplier', public.rpg_setting('level_cost_multiplier'),
    'settings', CASE WHEN gm.is_gm THEN
                  (SELECT coalesce(jsonb_agg(jsonb_build_object('key', s.key, 'value', s.value, 'label', s.label)
                     ORDER BY s.key), '[]'::jsonb)
                   FROM public.rpg_settings s
                   WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365')
                ELSE '[]'::jsonb END)
  FROM gm
  WHERE (SELECT public.rpg_can_play());
$function$;

-- rpg_sheet was last changed by an anchored patch, so it is patched the same way: two anchors, each exactly once.
DO $$
DECLARE v text := pg_get_functiondef('public.rpg_sheet(uuid,numeric)'::regprocedure);
BEGIN
  IF (length(v) - length(replace(v, 'rpg_template_stat_defs(v_c.template_key)', ''))) / length('rpg_template_stat_defs(v_c.template_key)') <> 1
     OR (length(v) - length(replace(v, '''template_key'', v_c.template_key', ''))) / length('''template_key'', v_c.template_key') <> 1 THEN
    RAISE EXCEPTION 'rpg_sheet anchors not found exactly once';
  END IF;
  v := replace(v, 'rpg_template_stat_defs(v_c.template_key)', 'rpg_template_stat_defs(v_c.template_id)');
  v := replace(v, '''template_key'', v_c.template_key', '''template_id'', v_c.template_id');
  EXECUTE v;
END $$;

-- The basic templates.
INSERT INTO public.rpg_creatures (key, name, sort_order, shown_to_players)
VALUES ('creature', 'Creature', -2, false), ('object', 'Object', -1, false);
UPDATE public.rpg_creatures SET parent_id = (SELECT id FROM public.rpg_creatures WHERE key = 'creature')
 WHERE key IN ('human', 'bramblemaw', 'ashwing_harrier', 'mossback_elder', 'gloam_wisp', 'thornfield_boar');
-- Spirit, Mind and every shared skill belong to Creature; Body and what is figured only from Body stay shared.
UPDATE public.rpg_stat_definitions SET template_id = (SELECT id FROM public.rpg_creatures WHERE key = 'creature')
 WHERE template_id IS NULL AND key NOT IN ('ST', 'AG', 'TO', 'PV', 'IG');

ALTER TABLE public.rpg_characters DROP COLUMN template_key;
ALTER TABLE public.rpg_stat_definitions DROP COLUMN template_key;

DO $$
DECLARE v text; k text;
BEGIN
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prokind = 'f' AND p.proname LIKE 'rpg%' AND pg_get_functiondef(p.oid) ~ 'template_key';
  IF v IS NOT NULL THEN RAISE EXCEPTION 'template_key still read by: %', v; END IF;
  -- Nothing shared may be figured from a stat an Object does not have.
  SELECT string_agg(d.key, ', ') INTO k FROM public.rpg_stat_definitions d, jsonb_array_elements(coalesce(d.formula->'parts', '[]')) p
   WHERE d.template_id IS NULL AND NOT EXISTS (SELECT 1 FROM public.rpg_stat_definitions s WHERE s.key = p->>0 AND s.template_id IS NULL);
  IF k IS NOT NULL THEN RAISE EXCEPTION 'shared stats built on Creature-only stats: %', k; END IF;
  IF NOT has_function_privilege('authenticated', 'public.rpg_new_character(text,uuid,boolean,uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.rpg_template_stat_defs(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.rpg_new_character(text,uuid,boolean,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'grants are wrong';
  END IF;
END $$;
