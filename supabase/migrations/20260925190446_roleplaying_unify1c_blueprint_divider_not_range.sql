-- Roleplaying unification, step 1 follow-up (Peter 2026-09-25): no preset ranges in a card. Every character keeps the one
-- rolling rule: a d100 (1 to 100) divided by a divider, rounded up. A card may change a trait's divider (decimals and
-- dividers under 1 allowed) or set a number, the same every time, the way a boss is made. The [low, high] form goes.
-- All blueprints are {} today, so no stored data changes.

COMMENT ON COLUMN public.rpg_creatures.blueprint IS 'How a character made from this card is rolled. {stat key: number} sets that stat, the same every time (a boss). {stat key: {"divisor": n}} rolls that trait d100 ÷ n, rounded up (10 is the standard: a 47 makes 5, so 1 to 10; 5 makes 1 to 20; 0.5 makes 2 to 200). Stats left out come from the parent card, then the standard divider.';

-- 1. Guard a card's parent and blueprint before they save.
CREATE OR REPLACE FUNCTION public.rpg_creatures_template_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Parent: a card can never end up above itself (Wolf under Grey Wolf under Wolf is refused).
-- Blueprint: each entry is a stat key and either a whole number, set the same every time ({"ST": 10}, the way a boss
-- is made), or the divider that rolled stat rolls with ({"ST": {"divisor": 5}}: d100 ÷ 5, rounded up, so 1 to 20;
-- decimals and dividers under 1 are fine). A divider goes on a rolled stat only. A calculated stat such as Physical
-- Vitality comes from the sheet, never the blueprint. Peter 2026-09-25: no preset ranges; every character keeps the
-- rolling rule.
DECLARE
  v_key  text;
  v_val  jsonb;
  v_kind text;
  v_n    numeric;
BEGIN
  IF NEW.parent_key IS NOT NULL
     AND (NEW.parent_key = NEW.key OR NEW.key = ANY (public.rpg_template_chain(NEW.parent_key))) THEN
    RAISE EXCEPTION '% cannot be made from %: it would sit above itself', NEW.name, NEW.parent_key;
  END IF;
  IF NEW.blueprint IS NULL OR jsonb_typeof(NEW.blueprint) <> 'object' THEN
    RAISE EXCEPTION '%: a blueprint lists stats and their numbers', NEW.name;
  END IF;
  FOR v_key, v_val IN SELECT b.key, b.value FROM jsonb_each(NEW.blueprint) AS b LOOP
    SELECT d.kind INTO v_kind FROM public.rpg_template_stat_defs(NEW.parent_key) d
     WHERE d.key = v_key AND d.kind IN ('rolled','fixed');
    IF v_kind IS NULL THEN
      SELECT d.kind INTO v_kind FROM public.rpg_stat_definitions d
       WHERE d.agency_id = NEW.agency_id AND d.template_key = NEW.key AND d.key = v_key AND d.kind IN ('rolled','fixed');
    END IF;
    IF v_kind IS NULL THEN
      RAISE EXCEPTION '% blueprint: % is not a rolled or fixed stat this card has', NEW.name, v_key;
    END IF;
    IF jsonb_typeof(v_val) = 'number' THEN
      v_n := (v_val #>> '{}')::numeric;
      IF v_n < 0 OR v_n <> trunc(v_n) THEN
        RAISE EXCEPTION '% blueprint: % must be a whole number, 0 or more (got %)', NEW.name, v_key, v_val;
      END IF;
    ELSIF jsonb_typeof(v_val) = 'object' THEN
      IF v_kind <> 'rolled' THEN
        RAISE EXCEPTION '% blueprint: % is not rolled, so it takes a set number, not a divider', NEW.name, v_key;
      END IF;
      IF (SELECT count(*) FROM jsonb_object_keys(v_val)) <> 1 OR jsonb_typeof(v_val -> 'divisor') <> 'number' THEN
        RAISE EXCEPTION '% blueprint: % must be a set number or {"divisor": n} (got %)', NEW.name, v_key, v_val;
      END IF;
      IF (v_val ->> 'divisor')::numeric <= 0 THEN
        RAISE EXCEPTION '% blueprint: % divider must be above 0 (got %)', NEW.name, v_key, v_val;
      END IF;
    ELSE
      RAISE EXCEPTION '% blueprint: % must be a set number or {"divisor": n} (got %)', NEW.name, v_key, v_val;
    END IF;
  END LOOP;
  RETURN NEW;
END;
$function$;

-- 2. The one generator, by card: every rolled stat follows the rolling rule with its divider.
CREATE OR REPLACE FUNCTION public.rpg_roll_inputs(p_template_key text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A new character's inputs from the card it is made from. Every rolled stat follows the one rolling rule: a d100
-- (1 to 100) divided by its divider, rounded up. The standard divider is the strength_roll_divisor setting (10: a 47
-- makes 5, so 1 to 10). A card may give a stat its own divider ({"ST": {"divisor": 5}}: a 47 makes 10, so 1 to 20;
-- 0.5 gives 2 to 200) or a set number, the same every time, the way a boss is made. A fixed stat starts at its
-- default (Sword of the Spirit 1) unless the card sets it.
SELECT public.require_login('family');
  SELECT coalesce(jsonb_object_agg(d.key,
           CASE
             WHEN jsonb_typeof(b.bp -> d.key) = 'number' THEN (b.bp ->> d.key)::numeric
             WHEN d.kind = 'rolled' THEN
               ceil((floor(random() * public.rpg_setting('strength_roll_max')) + 1)
                    / coalesce((b.bp -> d.key ->> 'divisor')::numeric, public.rpg_setting('strength_roll_divisor')))
             ELSE d.default_value
           END), '{}'::jsonb)
    FROM public.rpg_template_stat_defs(p_template_key) d
   CROSS JOIN (SELECT public.rpg_template_blueprint(p_template_key) AS bp) b
   WHERE d.kind IN ('rolled','fixed');
$function$;

REVOKE ALL ON FUNCTION public.rpg_roll_inputs(text), public.rpg_creatures_template_check() FROM PUBLIC, anon, authenticated;

-- 3. The card tells the game master each entry as a set number or a divider (with the top it can land), not low/high.
DO $m$
DECLARE
  v_def text;
  v_old text;
  v_new text;
  v_i   integer;
BEGIN
  v_def := pg_get_functiondef('public.rpg_creature_card(uuid)'::regprocedure);
  FOR v_i IN 1..4 LOOP
    v_old := CASE v_i
      WHEN 1 THEN $a$'low',  CASE jsonb_typeof(b.value) WHEN 'array' THEN (b.value ->> 0)::numeric ELSE (b.value #>> '{}')::numeric END,$a$
      WHEN 2 THEN $a$'high', CASE jsonb_typeof(b.value) WHEN 'array' THEN (b.value ->> 1)::numeric ELSE (b.value #>> '{}')::numeric END,$a$
      WHEN 3 THEN $a$each as low and high (the same number when fixed). The standard roll$a$
      WHEN 4 THEN $a$-- for anything left out is d(die) ÷ divisor, rounded up.$a$ END;
    v_new := CASE v_i
      WHEN 1 THEN $a$'fixed',   CASE WHEN jsonb_typeof(b.value) = 'number' THEN (b.value #>> '{}')::numeric END,$a$
      WHEN 2 THEN $a$'divisor', CASE WHEN jsonb_typeof(b.value) = 'object' THEN (b.value ->> 'divisor')::numeric END, 'top', CASE WHEN jsonb_typeof(b.value) = 'object' THEN ceil(public.rpg_setting('strength_roll_max') / (b.value ->> 'divisor')::numeric) END,$a$
      WHEN 3 THEN $a$a set number (a boss) or the divider that stat rolls with; anything$a$
      WHEN 4 THEN $a$-- left out rolls with the standard divider (top = the highest a divider entry can land).$a$ END;
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
      RAISE EXCEPTION 'rpg_creature_card: anchor % is not there exactly once', v_i;
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END LOOP;
  EXECUTE v_def;
END $m$;

-- 4. The rule card: the divider paragraph replaces the range paragraph (the manual page follows by trigger).
UPDATE public.rpg_rules
   SET body = replace(body,
     'Another card can give a range instead: Strength 8 to 12 rolls one of 8, 9, 10, 11 or 12, each as likely. Or it can fix a number, the same every time, the way a boss is made.',
     'Another card can change the divider a trait rolls with: Strength divided by 5 turns a 47 into 10, so it lands 1 to 20. A divider can be a decimal or under 1: divided by 0.5, a 47 makes 94. Or a card can set a number, the same every time, the way a boss is made.')
 WHERE key = 'strength_roll' AND body LIKE '%Another card can give a range instead%';

-- 5. Guards.
DO $g$
BEGIN
  IF pg_get_functiondef('public.rpg_creature_card(uuid)'::regprocedure) LIKE '%''array''%' THEN
    RAISE EXCEPTION 'rpg_creature_card still reads the range form';
  END IF;
  IF pg_get_functiondef('public.rpg_roll_inputs(text)'::regprocedure) LIKE '%''array''%' THEN
    RAISE EXCEPTION 'rpg_roll_inputs still reads the range form';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rpg_rules WHERE key = 'strength_roll' AND body LIKE '%change the divider a trait rolls with%') THEN
    RAISE EXCEPTION 'the rule card did not take the divider paragraph';
  END IF;
  IF has_function_privilege('authenticated', 'public.rpg_roll_inputs(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'rpg_roll_inputs must not be callable by a login';
  END IF;
END $g$;

NOTIFY pgrst, 'reload schema';
