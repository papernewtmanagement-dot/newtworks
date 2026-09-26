-- Roleplaying unification, step 1 follow-up (Peter 2026-09-26): a card may change the divider a rolled trait rolls with,
-- but never below 1 (÷ 1 lands 1 to 100; ÷ 2 lands 1 to 50; the standard ÷ 10 lands 1 to 10), and may still give a
-- trainable skill experience points that climb the level ladder from wherever the roll lands. A set number stays.
-- Peter's cardinal rule, same day: creatures, characters and objects all use the same rules; no creature-only stats.

COMMENT ON COLUMN public.rpg_creatures.blueprint IS 'How a character made from this card is rolled. {stat key: number} sets a rolled or fixed stat, the same every time (a boss). {stat key: {"divisor": d}} rolls that trait d100 ÷ d, rounded up, d never under 1 (10 is the standard: a 47 makes 5, 1 to 10; 2 makes 1 to 50; 1 makes 1 to 100). {stat key: {"points": n}} gives a trainable stat n skill points of experience, spent up the level ladder (rpg_level_cost) from wherever the roll lands: 80,000 points take a 1 to 9 and a 10 to 13. One entry may carry both keys where the stat allows both. Stats left out come from the parent card, then the standard roll.';

-- 1. Guard a card's parent and blueprint before they save.
CREATE OR REPLACE FUNCTION public.rpg_creatures_template_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Parent: a card can never end up above itself (Wolf under Grey Wolf under Wolf is refused).
-- Blueprint: each entry is a stat key and either a whole number for a rolled or fixed stat, set the same every time
-- ({"ST": 33}, the way a boss is made), or an object with "divisor" (a rolled stat: d100 ÷ d rounded up, d at least 1,
-- so ÷ 2 lands 1 to 50) and/or "points" (a trainable stat: experience spent up the level ladder from the roll).
-- A calculated stat that cannot be trained (Physical Vitality) comes from the sheet, never the blueprint.
DECLARE
  v_key       text;
  v_val       jsonb;
  v_kind      text;
  v_trainable boolean;
  v_n         numeric;
  v_extra     text;
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
        IF NOT v_trainable THEN
          RAISE EXCEPTION '% blueprint: % cannot be trained, so it cannot take experience', NEW.name, v_key;
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

-- 2. The one generator: set numbers, otherwise the rolling rule with the card's divider (standard when none).
CREATE OR REPLACE FUNCTION public.rpg_roll_inputs(p_template_key text)
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
    FROM public.rpg_template_stat_defs(p_template_key) d
   CROSS JOIN (SELECT public.rpg_template_blueprint(p_template_key) AS bp) b
   WHERE d.kind IN ('rolled','fixed');
$function$;

-- 3. rpg_apply_experience spends only entries that carry points (a divider-only entry has none).
CREATE OR REPLACE FUNCTION public.rpg_apply_experience(p_character_id uuid, p_template_key text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- For every entry with "points" in the card's blueprint (its own and its parents'): start that stat over (a reroll
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
     WHERE jsonb_typeof(b.value) = 'object' AND jsonb_typeof(b.value -> 'points') = 'number'
     ORDER BY d.sort_order NULLS LAST, b.key
  LOOP
    DELETE FROM public.rpg_character_skills WHERE character_id = p_character_id AND stat_key = v_key;
    SELECT (s ->> 'value')::numeric INTO v_now
      FROM jsonb_array_elements(public.rpg_sheet(p_character_id) -> 'stats') s WHERE s ->> 'key' = v_key;
    PERFORM public.rpg_add_skill_points(p_character_id, v_key, v_pts, coalesce(v_now, 0));
  END LOOP;
END;
$function$;

-- 4. The card tells the game master each entry: set number, divider (with the top it can land), and/or points.
DO $m$
DECLARE
  v_def text;
  v_old text := $a$'points', CASE WHEN jsonb_typeof(b.value) = 'object' THEN (b.value ->> 'points')::numeric END,$a$;
  v_new text := $a$'divisor', CASE WHEN jsonb_typeof(b.value) = 'object' THEN (b.value ->> 'divisor')::numeric END, 'top', CASE WHEN jsonb_typeof(b.value) = 'object' AND (b.value ? 'divisor') THEN ceil(public.rpg_setting('strength_roll_max') / greatest((b.value ->> 'divisor')::numeric, 1)) END, 'points', CASE WHEN jsonb_typeof(b.value) = 'object' THEN (b.value ->> 'points')::numeric END,$a$;
BEGIN
  v_def := pg_get_functiondef('public.rpg_creature_card(uuid)'::regprocedure);
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'rpg_creature_card: the points anchor is not there exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $m$;

-- 5. The rule card: divider (never under 1) plus experience (the manual page follows by trigger).
UPDATE public.rpg_rules
   SET body = replace(body,
     'Another card can give a skill experience: the skill starts from the roll as above, then the card''s skill points climb the same level ladder a player climbs (a level costs 1,000 × (2 × level + 1), so 5 to 6 costs 11,000). 80,000 points take a 1 to 9 and a 10 to 13. Or a card can set a number, the same every time, the way a boss is made.',
     'Another card can change the divider a trait rolls with, never below 1: Strength divided by 2 turns a 47 into 24, so it lands 1 to 50; divided by 1 it lands 1 to 100. A card can also give a skill experience: the skill starts from its roll, then the card''s skill points climb the same level ladder a player climbs (a level costs 1,000 × (2 × level + 1), so 5 to 6 costs 11,000). 80,000 points take a 1 to 9 and a 10 to 13. Or a card can set a number, the same every time, the way a boss is made.')
 WHERE key = 'strength_roll' AND body LIKE '%Another card can give a skill experience: the skill starts from the roll as above%';

REVOKE ALL ON FUNCTION public.rpg_apply_experience(uuid, text), public.rpg_roll_inputs(text), public.rpg_creatures_template_check() FROM PUBLIC, anon, authenticated;
DO $g$
BEGIN
  IF pg_get_functiondef('public.rpg_creature_card(uuid)'::regprocedure) NOT LIKE '%''top'', CASE WHEN%' THEN
    RAISE EXCEPTION 'rpg_creature_card does not show the divider';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rpg_rules WHERE key = 'strength_roll' AND body LIKE '%never below 1%') THEN
    RAISE EXCEPTION 'the rule card did not take the divider paragraph';
  END IF;
  IF has_function_privilege('authenticated', 'public.rpg_roll_inputs(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'rpg_roll_inputs must not be callable by a login';
  END IF;
END $g$;

NOTIFY pgrst, 'reload schema';
