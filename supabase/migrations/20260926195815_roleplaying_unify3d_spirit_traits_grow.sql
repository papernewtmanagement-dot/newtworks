-- Roleplaying unification: Spirit traits grow when a creature is made (Peter 2026-09-26).
-- A card's experience may now go on a Spirit trait too. It grows by the pair rules, the same rules an event uses:
-- the root pair first (sort order), a fruit never past the root on its side, and what grows pulls the other side down.
-- The one place those rules live is rpg_move_trait; rpg_adjust_trait (a parent's event) and rpg_apply_experience (a
-- card's growth) both call it. An event at the cap is refused as before; a card's growth at the cap simply stops.

-- 1. The pair rules, in one place.
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
  SELECT d.* INTO v_d FROM public.rpg_template_stat_defs(v_c.template_key) d WHERE d.key = p_key;
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
REVOKE ALL ON FUNCTION public.rpg_move_trait(uuid, text, integer, boolean) FROM PUBLIC, anon, authenticated;

-- 2. An event (parents only) goes through it.
CREATE OR REPLACE FUNCTION public.rpg_adjust_trait(p_character_id uuid, p_key text, p_delta integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A parent's event on one trait (a kindness, a lie, a season of prayer): the pair rules in rpg_move_trait, strict, so
-- a fruit already at its root is refused with a message. Love 7 / Hatred 2, Hatred +3 → Hatred 5, Love 4. Returns the sheet.
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'parents only'; END IF;
  PERFORM public.rpg_move_trait(p_character_id, p_key, p_delta, true);
  RETURN public.rpg_sheet(p_character_id);
END;
$function$;

-- 3. A card's growth: Spirit traits through the pair rules, everything else up the ladder as before.
CREATE OR REPLACE FUNCTION public.rpg_apply_experience(p_character_id uuid, p_template_key text)
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
      FROM jsonb_each(public.rpg_template_blueprint(p_template_key)) b
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

-- 4. The card check: any rolled trait may take experience.
DO $$
DECLARE v_def text := pg_get_functiondef('public.rpg_creatures_template_check()'::regprocedure);
        v_i integer; v_old text; v_new text;
BEGIN
  FOR v_i IN 1..2 LOOP
    v_old := CASE v_i
      WHEN 1 THEN $o$-- so ÷ 2 lands 1 to 50) and/or "points" (experience spent up the level ladder from the roll: a skill, or a Mind or
-- Body trait growing into its kind's size; a Spirit trait moves only through events).$o$
      WHEN 2 THEN $o$        IF NOT v_trainable AND NOT (v_kind = 'rolled' AND EXISTS (
             SELECT 1 FROM public.rpg_stat_definitions d
              WHERE d.agency_id = NEW.agency_id AND d.key = v_key AND d.grp IN ('mind', 'physical') AND d.pair_key IS NULL)) THEN
          RAISE EXCEPTION '% blueprint: % cannot take experience (a skill or a Mind or Body trait can; a Spirit trait moves only through events)', NEW.name, v_key;
        END IF;$o$ END;
    v_new := CASE v_i
      WHEN 1 THEN $n$-- so ÷ 2 lands 1 to 50) and/or "points" (experience spent up the level ladder from the roll: a skill, or a trait
-- growing into its kind's size; a Spirit trait grows by the pair rules in rpg_move_trait).$n$
      WHEN 2 THEN $n$        IF NOT v_trainable AND v_kind <> 'rolled' THEN
          RAISE EXCEPTION '% blueprint: % cannot take experience (a skill or a rolled trait can)', NEW.name, v_key;
        END IF;$n$ END;
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
      RAISE EXCEPTION 'rpg_creatures_template_check: anchor % not found exactly once', v_i;
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END LOOP;
  EXECUTE v_def;
END $$;

COMMENT ON COLUMN public.rpg_creatures.blueprint IS 'How a character made from this card is rolled. {stat key: number} sets a rolled or fixed stat, the same every time (a boss). {stat key: {"divisor": d}} rolls that trait d100 ÷ d, rounded up, d never under 1 (10 is the standard: a 47 makes 5, 1 to 10; 2 makes 1 to 50; 1 makes 1 to 100). {stat key: {"points": n}} gives a skill or a trait n points of experience spent up the level ladder (rpg_level_cost) from wherever the roll lands: 80,000 points take a 1 to 9 and a 10 to 13. One entry may carry both keys: a Mossback''s Toughness rolls d100 ÷ 5, then 2,395,000 points take a 1 to 48 and a 20 to 52. A Spirit trait grows by the pair rules (rpg_move_trait): the root first, a fruit never past the root on its side, and what grows pulls the other side down. Stats left out come from the parent card, then the standard roll.';

-- 5. The four rolling cards: their Spirit traits grow too. Beasts' good sides roll d100 ÷ 20 (1 to 5) and grow to
--    about a human's 5 or 6, root first; the Gloam Wisp's evil sides roll d100 ÷ 10 and grow to about 10, its
--    Fascination with Evil to about 13. The skills' experience is retuned so a typical sheet stays on the old numbers.
UPDATE public.rpg_creatures c SET blueprint = m.bp::jsonb, updated_at = now()
  FROM (VALUES
    ('ashwing_harrier', '{"FE":0,"HT":0,"MI":0,"SR":0,"RA":0,"CR":0,"WK":0,"TR":0,"BU":0,"RK":0,"CG":{"divisor":20,"points":35000},"LO":{"divisor":20,"points":24000},"JO":{"divisor":20,"points":24000},"PE":{"divisor":20,"points":24000},"PA":{"divisor":20,"points":24000},"KI":{"divisor":20,"points":24000},"GO":{"divisor":20,"points":24000},"FA":{"divisor":20,"points":24000},"GE":{"divisor":20,"points":24000},"SC":{"divisor":20,"points":24000},"IN":{"divisor":20},"PR":{"divisor":15,"points":160000},"ST":{"divisor":15,"points":24000},"AG":{"divisor":15,"points":65000},"TO":{"divisor":15,"points":112000},"CO":{"points":11000},"EE":{"points":32000},"talon_dive":{"points":13000},"hunting_screech":{"points":11000}}'),
    ('mossback_elder', '{"FE":0,"HT":0,"MI":0,"SR":0,"RA":0,"CR":0,"WK":0,"TR":0,"BU":0,"RK":0,"CG":{"divisor":20,"points":35000},"LO":{"divisor":20,"points":24000},"JO":{"divisor":20,"points":24000},"PE":{"divisor":20,"points":24000},"PA":{"divisor":20,"points":24000},"KI":{"divisor":20,"points":24000},"GO":{"divisor":20,"points":24000},"FA":{"divisor":20,"points":24000},"GE":{"divisor":20,"points":24000},"SC":{"divisor":20,"points":24000},"IN":{"divisor":20},"ST":{"divisor":10,"points":117000},"AG":{"divisor":33},"TO":{"divisor":5,"points":2395000},"CO":{"points":56000},"EE":{"points":105000},"shell_slam":{"points":32000},"snapping_bite":{"points":28000}}'),
    ('gloam_wisp', '{"CG":0,"LO":0,"JO":0,"PE":0,"PA":0,"KI":0,"GO":0,"FA":0,"GE":0,"SC":0,"FE":{"divisor":10,"points":140000},"HT":{"divisor":10,"points":80000},"MI":{"divisor":10,"points":80000},"SR":{"divisor":10,"points":80000},"RA":{"divisor":10,"points":80000},"CR":{"divisor":10,"points":80000},"WK":{"divisor":10,"points":80000},"TR":{"divisor":10,"points":80000},"BU":{"divisor":10,"points":80000},"RK":{"divisor":10,"points":80000},"ST":{"divisor":40},"AG":{"divisor":20,"points":56000},"TO":{"divisor":20,"points":72000},"CO":{"points":40000},"EE":{"points":36000},"lure":{"points":15000},"cold_touch":{"points":11000}}'),
    ('thornfield_boar', '{"FE":0,"HT":0,"MI":0,"SR":0,"RA":0,"CR":0,"WK":0,"TR":0,"BU":0,"RK":0,"CG":{"divisor":20,"points":35000},"LO":{"divisor":20,"points":24000},"JO":{"divisor":20,"points":24000},"PE":{"divisor":20,"points":24000},"PA":{"divisor":20,"points":24000},"KI":{"divisor":20,"points":24000},"GO":{"divisor":20,"points":24000},"FA":{"divisor":20,"points":24000},"GE":{"divisor":20,"points":24000},"SC":{"divisor":20,"points":24000},"IN":{"divisor":20},"ST":{"divisor":10,"points":72000},"AG":{"divisor":10,"points":19000},"TO":{"divisor":10,"points":252000},"CO":{"points":24000},"EE":{"points":24000},"charge":{"points":15000}}')
  ) AS m(card, bp)
 WHERE c.key = m.card AND c.agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 6. The rule card (the admin manual page follows by trigger).
UPDATE public.rpg_rules
   SET body = replace(replace(body,
     'A card can also give experience, to a skill or to a Mind or Body trait: it starts from its roll,',
     'A card can also give experience, to a skill or to any trait: it starts from its roll,'),
     'Spirit traits never take experience; they move only through events.',
     'A Spirit trait grows the same way, by the pair rules below: the root grows first, a fruit never grows past the root on its side, and what grows pulls the other side down. A Gloam Wisp rolls Hatred d100 ÷ 10: a 34 makes 4, and 80,000 points of growth take it to 9, as long as its Fascination with Evil is at least 9.'),
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'strength_roll'
   AND body LIKE '%to a skill or to a Mind or Body trait%' AND body LIKE '%Spirit traits never take experience; they move only through events.%';

DO $$
BEGIN
  IF (SELECT count(*) FROM public.rpg_rules WHERE key = 'strength_roll' AND body LIKE '%A Gloam Wisp rolls Hatred d100 ÷ 10%') <> 1 THEN
    RAISE EXCEPTION 'rule card anchors did not match';
  END IF;
END $$;

