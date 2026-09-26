-- Roleplaying unification, step 1 follow-up (Peter 2026-09-26, decision 1A): a card gives a stat EXPERIENCE, not a divider.
-- Every rolled trait keeps the one rolling rule (d100 ÷ 10, rounded up: a 47 makes 5). A card may set a number on a
-- rolled or fixed stat (the same every time, the way a boss is made) or put skill points on a trainable stat; those
-- points climb the same level ladder a player climbs (rpg_level_cost: from 5 to 6 costs 1,000 × (2 × 5 + 1) = 11,000),
-- so 80,000 points take a 1 to 9 and a 10 to 13. The ladder lives in ONE place (rpg_climb_levels); rpg_roll's copy of
-- it moves into rpg_add_skill_points so a roll and a card's experience climb the same rungs. All blueprints are {} today.

COMMENT ON COLUMN public.rpg_creatures.blueprint IS 'How a character made from this card is rolled. {stat key: number} sets a rolled or fixed stat, the same every time (a boss). {stat key: {"points": n}} gives a trainable stat n skill points of experience, spent up the level ladder (rpg_level_cost) from wherever the standard roll lands: 80,000 points take a 1 to 9 and a 10 to 13. Stats left out come from the parent card, then roll the standard way (d100 ÷ 10, rounded up).';

-- 1. The one level ladder.
CREATE OR REPLACE FUNCTION public.rpg_climb_levels(p_start integer, p_points numeric)
 RETURNS TABLE(level integer, leftover numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Climbs from p_start while the points cover the next level (rpg_level_cost of the level you are on: from 5 to 6 costs
-- 1,000 × (2 × 5 + 1) = 11,000). Returns the level reached and the points left over. rpg_add_skill_points (a roll's
-- points, a card's experience) and rpg_creature_card (worked numbers) both use it; nothing else climbs on its own.
DECLARE
  v_level integer := coalesce(p_start, 0);
  v_sp    numeric := coalesce(p_points, 0);
  v_cost  numeric;
BEGIN
  LOOP
    v_cost := public.rpg_level_cost(v_level);
    EXIT WHEN v_cost <= 0 OR v_sp < v_cost;
    v_sp := v_sp - v_cost; v_level := v_level + 1;
  END LOOP;
  level := v_level; leftover := v_sp;
  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_add_skill_points(p_character_id uuid, p_stat_key text, p_points numeric, p_value_now numeric)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Adds skill points to a character's stat and turns them into earned levels with rpg_climb_levels, starting from the
-- stat's current value. Leftover points wait for the next level. Returns the value after. Used by rpg_roll (the points
-- a roll earns) and rpg_apply_experience (a card's experience), so both climb the same ladder.
DECLARE
  v_sp     numeric;
  v_earned integer;
  v_now    integer := coalesce(p_value_now, 0)::integer;
  v_level  integer;
  v_left   numeric;
BEGIN
  INSERT INTO public.rpg_character_skills (character_id, stat_key) VALUES (p_character_id, p_stat_key)
    ON CONFLICT (character_id, stat_key) DO NOTHING;
  SELECT skill_points, earned_levels INTO v_sp, v_earned
    FROM public.rpg_character_skills WHERE character_id = p_character_id AND stat_key = p_stat_key FOR UPDATE;
  SELECT c.level, c.leftover INTO v_level, v_left FROM public.rpg_climb_levels(v_now, v_sp + coalesce(p_points, 0)) c;
  UPDATE public.rpg_character_skills SET skill_points = v_left, earned_levels = v_earned + (v_level - v_now)
   WHERE character_id = p_character_id AND stat_key = p_stat_key;
  RETURN v_level;
END;
$function$;

-- 2. rpg_roll hands its ladder to rpg_add_skill_points (same effect, one copy of the rule).
DO $m$
DECLARE
  v_def text;
  v_a   integer;
  v_b   integer;
  v_c   integer;
  v_cut text;
  v_ins text := 'v_after := public.rpg_add_skill_points(p_character_id, p_stat_key, v_points, v_before);';
BEGIN
  v_def := pg_get_functiondef('public.rpg_roll(uuid,text,numeric,text,uuid,uuid,uuid,numeric,integer)'::regprocedure);
  v_a := position('INSERT INTO public.rpg_character_skills (character_id, stat_key) VALUES (p_character_id, p_stat_key)' in v_def);
  v_b := position('UPDATE public.rpg_character_skills SET skill_points = v_sp, earned_levels = v_earned' in v_def);
  IF v_a = 0 OR v_b = 0 OR v_b < v_a THEN RAISE EXCEPTION 'rpg_roll: the ladder block is not where expected'; END IF;
  v_c := v_b + position(';' in substring(v_def from v_b)) - 1;
  v_cut := substring(v_def from v_a for v_c - v_a + 1);
  IF v_cut NOT LIKE '%EXIT WHEN v_sp < v_cost;%' OR (length(v_cut) - length(replace(v_cut, 'LOOP', ''))) / 4 <> 2 THEN
    RAISE EXCEPTION 'rpg_roll: the ladder block does not look like the ladder';
  END IF;
  EXECUTE substring(v_def from 1 for v_a - 1) || v_ins || substring(v_def from v_c + 1);
END $m$;

-- 3. Guard a card's parent and blueprint before they save.
CREATE OR REPLACE FUNCTION public.rpg_creatures_template_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Parent: a card can never end up above itself (Wolf under Grey Wolf under Wolf is refused).
-- Blueprint: each entry is a stat key and either a whole number for a rolled or fixed stat, set the same every time
-- ({"ST": 33}, the way a boss is made), or experience for a trainable stat ({"EE": {"points": 80000}}), spent up the
-- level ladder from wherever the standard roll lands. A calculated stat that cannot be trained (Physical Vitality)
-- comes from the sheet, never the blueprint. Peter 2026-09-26: no ranges, no dividers; every character keeps the rolling rule.
DECLARE
  v_key       text;
  v_val       jsonb;
  v_kind      text;
  v_trainable boolean;
  v_n         numeric;
BEGIN
  IF NEW.parent_key IS NOT NULL
     AND (NEW.parent_key = NEW.key OR NEW.key = ANY (public.rpg_template_chain(NEW.parent_key))) THEN
    RAISE EXCEPTION '% cannot be made from %: it would sit above itself', NEW.name, NEW.parent_key;
  END IF;
  IF NEW.blueprint IS NULL OR jsonb_typeof(NEW.blueprint) <> 'object' THEN
    RAISE EXCEPTION '%: a blueprint lists stats and their numbers', NEW.name;
  END IF;
  FOR v_key, v_val IN SELECT b.key, b.value FROM jsonb_each(NEW.blueprint) AS b LOOP
    v_kind := NULL;
    SELECT d.kind, coalesce(d.trainable, false) INTO v_kind, v_trainable
      FROM public.rpg_template_stat_defs(NEW.parent_key) d WHERE d.key = v_key;
    IF v_kind IS NULL THEN
      SELECT d.kind, coalesce(d.trainable, false) INTO v_kind, v_trainable FROM public.rpg_stat_definitions d
       WHERE d.agency_id = NEW.agency_id AND d.template_key = NEW.key AND d.key = v_key;
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
      IF (SELECT count(*) FROM jsonb_object_keys(v_val)) <> 1 OR jsonb_typeof(v_val -> 'points') IS DISTINCT FROM 'number' THEN
        RAISE EXCEPTION '% blueprint: % must be a set number or {"points": n} (got %)', NEW.name, v_key, v_val;
      END IF;
      IF NOT v_trainable THEN
        RAISE EXCEPTION '% blueprint: % cannot be trained, so it takes a set number, not experience', NEW.name, v_key;
      END IF;
      IF (v_val ->> 'points')::numeric < 0 THEN
        RAISE EXCEPTION '% blueprint: % experience must be 0 or more (got %)', NEW.name, v_key, v_val;
      END IF;
    ELSE
      RAISE EXCEPTION '% blueprint: % must be a set number or {"points": n} (got %)', NEW.name, v_key, v_val;
    END IF;
  END LOOP;
  RETURN NEW;
END;
$function$;

-- 4. The one generator: set numbers, otherwise the standard roll.
CREATE OR REPLACE FUNCTION public.rpg_roll_inputs(p_template_key text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A new character's inputs from the card it is made from. Every rolled stat follows the one rolling rule: a d100
-- (1 to 100) divided by the strength_roll_divisor setting (10), rounded up: a 47 makes 5, so 1 to 10. A card may set
-- a number instead, the same every time, the way a boss is made. A fixed stat starts at its default (Sword of the
-- Spirit 1) unless the card sets it. A card's experience is spent afterwards by rpg_apply_experience.
SELECT public.require_login('family');
  SELECT coalesce(jsonb_object_agg(d.key,
           CASE
             WHEN jsonb_typeof(b.bp -> d.key) = 'number' THEN (b.bp ->> d.key)::numeric
             WHEN d.kind = 'rolled' THEN
               ceil((floor(random() * public.rpg_setting('strength_roll_max')) + 1) / public.rpg_setting('strength_roll_divisor'))
             ELSE d.default_value
           END), '{}'::jsonb)
    FROM public.rpg_template_stat_defs(p_template_key) d
   CROSS JOIN (SELECT public.rpg_template_blueprint(p_template_key) AS bp) b
   WHERE d.kind IN ('rolled','fixed');
$function$;

-- 5. A card's experience, spent through the same ladder, stat by stat in sheet order.
CREATE OR REPLACE FUNCTION public.rpg_apply_experience(p_character_id uuid, p_template_key text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- For every {"points": n} entry in the card's blueprint (its own and its parents'): start that stat over (a reroll
-- makes the character again) and spend the points from the stat's value on the fresh sheet. Traits go first so a skill
-- built on them sees their final numbers. Used by rpg_new_character and rpg_reroll_character.
DECLARE
  v_key text;
  v_pts numeric;
  v_now numeric;
BEGIN
  FOR v_key, v_pts IN
    SELECT b.key, (b.value ->> 'points')::numeric
      FROM jsonb_each(public.rpg_template_blueprint(p_template_key)) b
      LEFT JOIN public.rpg_stat_definitions d ON d.key = b.key AND d.agency_id = '126794dd-25ff-47d2-a436-724499733365'
     WHERE jsonb_typeof(b.value) = 'object'
     ORDER BY d.sort_order NULLS LAST, b.key
  LOOP
    DELETE FROM public.rpg_character_skills WHERE character_id = p_character_id AND stat_key = v_key;
    SELECT (s ->> 'value')::numeric INTO v_now
      FROM jsonb_array_elements(public.rpg_sheet(p_character_id) -> 'stats') s WHERE s ->> 'key' = v_key;
    PERFORM public.rpg_add_skill_points(p_character_id, v_key, v_pts, coalesce(v_now, 0));
  END LOOP;
END;
$function$;

DO $m$
DECLARE
  v_def text;
  v_old text := 'RETURNING id INTO v_id;';
BEGIN
  v_def := pg_get_functiondef('public.rpg_new_character(text,uuid,boolean,text)'::regprocedure);
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'rpg_new_character: the insert anchor is not there exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_old || E'\n  PERFORM public.rpg_apply_experience(v_id, v_key);');
END $m$;

CREATE OR REPLACE FUNCTION public.rpg_reroll_character(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The character made again from its own card: a Human rolls every trait again; a card's set numbers come back the
-- same; a card's experience is spent again from the new roll.
DECLARE
  v_card text;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF NOT public.family_is_parent() AND EXISTS (SELECT 1 FROM public.rpg_rolls WHERE character_id = p_character_id) THEN
    RAISE EXCEPTION 'this character has already played; ask a parent to re-roll';
  END IF;
  UPDATE public.rpg_characters SET inputs = public.rpg_roll_inputs(template_key) WHERE id = p_character_id
  RETURNING template_key INTO v_card;
  PERFORM public.rpg_apply_experience(p_character_id, v_card);
  RETURN public.rpg_sheet(p_character_id);
END;
$function$;

-- 6. The card tells the game master each entry as a set number or experience, with where those points take a 1 and a 10.
DO $m$
DECLARE
  v_def text;
  v_old text;
  v_new text;
  v_i   integer;
BEGIN
  v_def := pg_get_functiondef('public.rpg_creature_card(uuid)'::regprocedure);
  FOR v_i IN 1..3 LOOP
    v_old := CASE v_i
      WHEN 1 THEN $a$'divisor', CASE WHEN jsonb_typeof(b.value) = 'object' THEN (b.value ->> 'divisor')::numeric END, 'top', CASE WHEN jsonb_typeof(b.value) = 'object' THEN ceil(public.rpg_setting('strength_roll_max') / (b.value ->> 'divisor')::numeric) END,$a$
      WHEN 2 THEN $a$a set number (a boss) or the divider that stat rolls with; anything$a$
      WHEN 3 THEN $a$-- left out rolls with the standard divider (top = the highest a divider entry can land).$a$ END;
    v_new := CASE v_i
      WHEN 1 THEN $a$'points', CASE WHEN jsonb_typeof(b.value) = 'object' THEN (b.value ->> 'points')::numeric END, 'from_1', CASE WHEN jsonb_typeof(b.value) = 'object' THEN (SELECT c.level FROM public.rpg_climb_levels(1, (b.value ->> 'points')::numeric) c) END, 'from_10', CASE WHEN jsonb_typeof(b.value) = 'object' THEN (SELECT c.level FROM public.rpg_climb_levels(10, (b.value ->> 'points')::numeric) c) END,$a$
      WHEN 2 THEN $a$a set number (a boss) or experience points spent up the level ladder$a$
      WHEN 3 THEN $a$-- (from_1 and from_10: where those points take a 1 and a 10). Anything left out rolls the standard way.$a$ END;
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
      RAISE EXCEPTION 'rpg_creature_card: anchor % is not there exactly once', v_i;
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END LOOP;
  EXECUTE v_def;
END $m$;

-- 7. The rule card: experience replaces the divider paragraph (the manual page follows by trigger).
UPDATE public.rpg_rules
   SET body = replace(body,
     'Another card can change the divider a trait rolls with: Strength divided by 5 turns a 47 into 10, so it lands 1 to 20. A divider can be a decimal or under 1: divided by 0.5, a 47 makes 94. Or a card can set a number, the same every time, the way a boss is made.',
     'Another card can give a skill experience: the skill starts from the roll as above, then the card''s skill points climb the same level ladder a player climbs (a level costs 1,000 × (2 × level + 1), so 5 to 6 costs 11,000). 80,000 points take a 1 to 9 and a 10 to 13. Or a card can set a number, the same every time, the way a boss is made.')
 WHERE key = 'strength_roll' AND body LIKE '%Another card can change the divider a trait rolls with%';

-- 8. Grants and guards.
REVOKE ALL ON FUNCTION public.rpg_climb_levels(integer, numeric), public.rpg_add_skill_points(uuid, text, numeric, numeric),
  public.rpg_apply_experience(uuid, text), public.rpg_roll_inputs(text), public.rpg_creatures_template_check() FROM PUBLIC, anon, authenticated;
DO $g$
BEGIN
  IF pg_get_functiondef('public.rpg_roll(uuid,text,numeric,text,uuid,uuid,uuid,numeric,integer)'::regprocedure) LIKE '%EXIT WHEN v_sp < v_cost%' THEN
    RAISE EXCEPTION 'rpg_roll still carries its own ladder';
  END IF;
  IF pg_get_functiondef('public.rpg_roll(uuid,text,numeric,text,uuid,uuid,uuid,numeric,integer)'::regprocedure) NOT LIKE '%rpg_add_skill_points(p_character_id, p_stat_key, v_points, v_before)%' THEN
    RAISE EXCEPTION 'rpg_roll does not call the ladder';
  END IF;
  IF pg_get_functiondef('public.rpg_new_character(text,uuid,boolean,text)'::regprocedure) NOT LIKE '%rpg_apply_experience(v_id, v_key)%' THEN
    RAISE EXCEPTION 'rpg_new_character does not spend experience';
  END IF;
  IF pg_get_functiondef('public.rpg_creature_card(uuid)'::regprocedure) LIKE '%divisor'')::numeric%' THEN
    RAISE EXCEPTION 'rpg_creature_card still reads a divider';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rpg_rules WHERE key = 'strength_roll' AND body LIKE '%give a skill experience%') THEN
    RAISE EXCEPTION 'the rule card did not take the experience paragraph';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.rpg_new_character(text, uuid, boolean, text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpg_reroll_character(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpg_roll(uuid,text,numeric,text,uuid,uuid,uuid,numeric,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'a login-facing function lost its grant';
  END IF;
  IF has_function_privilege('authenticated', 'public.rpg_add_skill_points(uuid, text, numeric, numeric)', 'EXECUTE') THEN
    RAISE EXCEPTION 'the ladder must not be callable by a login';
  END IF;
END $g$;

NOTIFY pgrst, 'reload schema';
