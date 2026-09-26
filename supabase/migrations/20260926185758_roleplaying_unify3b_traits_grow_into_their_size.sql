-- Roleplaying unification, creature cards grow into their size (Peter 2026-09-26).
-- Peter's ruling (decision 1A of the blueprint step, then dividers kept): a trait rolls with its card's divider, then the
-- creature is leveled up as though it had lived, with experience spent up the one level ladder. The first build let only
-- skills take experience and refused it on traits, so the cards leaned on wide dividers and a Mossback could land anywhere
-- from 41 to 314 vitality. Now a Mind or Body trait takes experience too; because every level costs more than the last,
-- a big creature ends up near its kind's size whatever it rolled. Spirit traits still move only through events.
-- Players still cannot train a trait in play (rpg_roll earns points only on trainable stats).

-- 1. The card check: experience on a skill, or on a Mind or Body trait.
DO $$
DECLARE v_def text := pg_get_functiondef('public.rpg_creatures_template_check()'::regprocedure);
        v_i integer; v_old text; v_new text;
BEGIN
  FOR v_i IN 1..2 LOOP
    v_old := CASE v_i
      WHEN 1 THEN $o$-- so ÷ 2 lands 1 to 50) and/or "points" (a trainable stat: experience spent up the level ladder from the roll).$o$
      WHEN 2 THEN $o$        IF NOT v_trainable THEN
          RAISE EXCEPTION '% blueprint: % cannot be trained, so it cannot take experience', NEW.name, v_key;
        END IF;$o$ END;
    v_new := CASE v_i
      WHEN 1 THEN $n$-- so ÷ 2 lands 1 to 50) and/or "points" (experience spent up the level ladder from the roll: a skill, or a Mind or
-- Body trait growing into its kind's size; a Spirit trait moves only through events).$n$
      WHEN 2 THEN $n$        IF NOT v_trainable AND NOT (v_kind = 'rolled' AND EXISTS (
             SELECT 1 FROM public.rpg_stat_definitions d
              WHERE d.agency_id = NEW.agency_id AND d.key = v_key AND d.grp IN ('mind', 'physical') AND d.pair_key IS NULL)) THEN
          RAISE EXCEPTION '% blueprint: % cannot take experience (a skill or a Mind or Body trait can; a Spirit trait moves only through events)', NEW.name, v_key;
        END IF;$n$ END;
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
      RAISE EXCEPTION 'rpg_creatures_template_check: anchor % not found exactly once', v_i;
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END LOOP;
  EXECUTE v_def;
END $$;

COMMENT ON COLUMN public.rpg_creatures.blueprint IS 'How a character made from this card is rolled. {stat key: number} sets a rolled or fixed stat, the same every time (a boss). {stat key: {"divisor": d}} rolls that trait d100 ÷ d, rounded up, d never under 1 (10 is the standard: a 47 makes 5, 1 to 10; 2 makes 1 to 50; 1 makes 1 to 100). {stat key: {"points": n}} gives a skill, or a Mind or Body trait, n points of experience spent up the level ladder (rpg_level_cost) from wherever the roll lands: 80,000 points take a 1 to 9 and a 10 to 13. One entry may carry both keys: a Mossback''s Toughness rolls d100 ÷ 5, then 2,395,000 points take a 1 to 48 and a 20 to 52. Spirit traits never take experience. Stats left out come from the parent card, then the standard roll.';

-- 2. The GM card: where a card's experience takes the bottom and the top of that stat's own roll.
DO $$
DECLARE v_def text := pg_get_functiondef('public.rpg_creature_card(uuid)'::regprocedure);
        v_i integer; v_old text; v_new text;
BEGIN
  FOR v_i IN 1..2 LOOP
    v_old := CASE v_i
      WHEN 1 THEN $o$'from_10', CASE WHEN jsonb_typeof(b.value) = 'object' THEN (SELECT c.level FROM public.rpg_climb_levels(10, (b.value ->> 'points')::numeric) c) END,$o$
      WHEN 2 THEN $o$    -- (from_1 and from_10: where those points take a 1 and a 10). Anything left out rolls the standard way.$o$ END;
    v_new := CASE v_i
      WHEN 1 THEN $n$'start_top', CASE WHEN jsonb_typeof(b.value) = 'object' AND (b.value ? 'points') THEN coalesce(ceil(public.rpg_setting('strength_roll_max') / greatest((b.value ->> 'divisor')::numeric, 1)), ceil(public.rpg_setting('strength_roll_max') / public.rpg_setting('strength_roll_divisor'))) END, 'from_top', CASE WHEN jsonb_typeof(b.value) = 'object' AND (b.value ? 'points') THEN (SELECT c.level FROM public.rpg_climb_levels(coalesce(ceil(public.rpg_setting('strength_roll_max') / greatest((b.value ->> 'divisor')::numeric, 1)), ceil(public.rpg_setting('strength_roll_max') / public.rpg_setting('strength_roll_divisor')))::integer, (b.value ->> 'points')::numeric) c) END,$n$
      WHEN 2 THEN $n$    -- (from_1 and from_top: where those points take a 1 and start_top, the top of that stat's own roll). Anything
    -- left out rolls the standard way.$n$ END;
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
      RAISE EXCEPTION 'rpg_creature_card: anchor % not found exactly once', v_i;
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END LOOP;
  EXECUTE v_def;
END $$;

-- 3. The four rolling cards: each kind keeps its own dividers, and its traits grow into its size.
--    Typical sheets still land on the old fight numbers; vitality, 90% of creatures:
--    Harrier 40 to 50, Mossback 166 to 182, Wisp 26 to 33, Boar 63 to 77.
UPDATE public.rpg_creatures c SET blueprint = m.bp::jsonb, updated_at = now()
  FROM (VALUES
    ('ashwing_harrier', '{"FE":0,"HT":0,"MI":0,"SR":0,"RA":0,"CR":0,"WK":0,"TR":0,"BU":0,"RK":0,"IN":{"divisor":20},"PR":{"divisor":15,"points":160000},"ST":{"divisor":15,"points":24000},"AG":{"divisor":15,"points":65000},"TO":{"divisor":15,"points":112000},"CO":{"points":13000},"EE":{"points":32000},"talon_dive":{"points":13000},"hunting_screech":{"points":11000}}'),
    ('mossback_elder', '{"FE":0,"HT":0,"MI":0,"SR":0,"RA":0,"CR":0,"WK":0,"TR":0,"BU":0,"RK":0,"IN":{"divisor":20},"ST":{"divisor":10,"points":117000},"AG":{"divisor":33},"TO":{"divisor":5,"points":2395000},"CO":{"points":56000},"EE":{"points":105000},"shell_slam":{"points":32000},"snapping_bite":{"points":28000}}'),
    ('gloam_wisp', '{"CG":0,"LO":0,"JO":0,"PE":0,"PA":0,"KI":0,"GO":0,"FA":0,"GE":0,"SC":0,"FE":{"divisor":5},"HT":{"divisor":5},"MI":{"divisor":5},"SR":{"divisor":5},"RA":{"divisor":5},"CR":{"divisor":5},"WK":{"divisor":5},"TR":{"divisor":5},"BU":{"divisor":5},"RK":{"divisor":5},"ST":{"divisor":40},"AG":{"divisor":20,"points":56000},"TO":{"divisor":20,"points":72000},"CO":{"points":40000},"EE":{"points":32000},"lure":{"points":24000},"cold_touch":{"points":11000}}'),
    ('thornfield_boar', '{"FE":0,"HT":0,"MI":0,"SR":0,"RA":0,"CR":0,"WK":0,"TR":0,"BU":0,"RK":0,"IN":{"divisor":20},"ST":{"divisor":10,"points":72000},"AG":{"divisor":10,"points":19000},"TO":{"divisor":10,"points":252000},"CO":{"points":27000},"EE":{"points":24000},"charge":{"points":15000}}')
  ) AS m(card, bp)
 WHERE c.key = m.card AND c.agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 4. rpg_new_character's worked example follows the Boar's new recipe.
DO $$
DECLARE v_def text := pg_get_functiondef('public.rpg_new_character(text, uuid, boolean, text)'::regprocedure);
        v_old text := $o$(a Thornfield Boar rolls Toughness d100 ÷ 3, so a 47 makes 16).$o$;
        v_new text := $n$(a Thornfield Boar rolls Toughness d100 ÷ 10, so a 47 makes 5, and its card's growth takes that to 16).$n$;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'rpg_new_character: anchor not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $$;

-- 5. The rule cards (the admin manual page follows by trigger).
UPDATE public.rpg_rules
   SET body = replace(body,
     $o$A card can also give a skill experience: the skill starts from its roll, then the card's skill points climb the same level ladder a player climbs (a level costs 1,000 × (2 × level + 1), so 5 to 6 costs 11,000). 80,000 points take a 1 to 9 and a 10 to 13.$o$,
     $n$A card can also give experience, to a skill or to a Mind or Body trait: it starts from its roll, then the card's points climb the same level ladder a player climbs (a level costs 1,000 × (2 × level + 1), so 5 to 6 costs 11,000). 80,000 points take a 1 to 9 and a 10 to 13. That is how a creature grows into its size, and because every level costs more than the last, a big creature ends up close to its kind's size whatever it rolled: a Mossback Elder rolls Toughness d100 ÷ 5, 1 to 20, then 2,395,000 points take a 1 to 48 and a 20 to 52. Spirit traits never take experience; they move only through events.$n$),
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'strength_roll'
   AND body LIKE '%A card can also give a skill experience: the skill starts from its roll%';

UPDATE public.rpg_rules
   SET body = replace(body,
     $o$*A Thornfield Boar rolls Toughness d100 ÷ 3, rounded up: a 47 makes 16. Its Physical Vitality$o$,
     $n$*A Thornfield Boar rolls Toughness d100 ÷ 10, rounded up: a 47 makes 5, and its card's 252,000 points of growth take that 5 to 16. Its Physical Vitality$n$),
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'creature_conversion'
   AND body LIKE '%A Thornfield Boar rolls Toughness d100 ÷ 3, rounded up%';

DO $$
BEGIN
  IF (SELECT count(*) FROM public.rpg_rules WHERE key = 'strength_roll' AND body LIKE '%grows into its size%') <> 1
     OR (SELECT count(*) FROM public.rpg_rules WHERE key = 'creature_conversion' AND body LIKE '%252,000 points of growth%') <> 1 THEN
    RAISE EXCEPTION 'rule card anchors did not match';
  END IF;
END $$;

