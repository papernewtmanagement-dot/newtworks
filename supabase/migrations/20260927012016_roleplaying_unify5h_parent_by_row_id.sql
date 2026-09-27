-- Roleplaying unify5h: a card's parent is another card's row id, never a typed key (Peter 2026-09-27), and the
-- hand-typed action notes are gone (Peter: "Delete the old shit"). No card has a parent today, so nothing moves.

ALTER TABLE public.rpg_creatures ADD COLUMN IF NOT EXISTS parent_id uuid REFERENCES public.rpg_creatures(id);
UPDATE public.rpg_creatures c SET parent_id = p.id FROM public.rpg_creatures p
 WHERE c.parent_key IS NOT NULL AND p.agency_id = c.agency_id AND p.key = c.parent_key;

CREATE OR REPLACE FUNCTION public.rpg_template_chain(p_template_key text)
 RETURNS text[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A card and every card above it, nearest first, walking each card's parent row id (parent_id). A Grey Wolf card
-- made from Wolf gives {grey_wolf, wolf}; Human gives {human}. The one place that says what a card is made of.
-- Stops at ten levels and never visits a card twice.
WITH RECURSIVE up AS (
  SELECT c.id, c.key, c.parent_id, 1 AS depth, ARRAY[c.id] AS path
    FROM public.rpg_creatures c
   WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.key = p_template_key
  UNION ALL
  SELECT c.id, c.key, c.parent_id, up.depth + 1, up.path || c.id
    FROM up
    JOIN public.rpg_creatures c ON c.id = up.parent_id
   WHERE up.depth < 10 AND NOT c.id = ANY (up.path)
)
SELECT coalesce(array_agg(key ORDER BY depth), '{}'::text[]) FROM up;
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
                      FROM jsonb_each(public.rpg_template_blueprint(v_c.key)) AS b
                      JOIN public.rpg_template_stat_defs(v_c.key) d ON d.key = b.key)),
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
  v_pkey      text;
  v_pname     text;
BEGIN
  IF NEW.parent_id IS NOT NULL THEN
    SELECT p.key, p.name INTO v_pkey, v_pname FROM public.rpg_creatures p WHERE p.id = NEW.parent_id;
    IF v_pkey IS NULL THEN
      RAISE EXCEPTION '% cannot be made from that card: it is not on the list', NEW.name;
    END IF;
    IF NEW.parent_id = NEW.id OR NEW.key = ANY (public.rpg_template_chain(v_pkey)) THEN
      RAISE EXCEPTION '% cannot be made from %: it would sit above itself', NEW.name, v_pname;
    END IF;
  END IF;
  IF NEW.blueprint IS NULL OR jsonb_typeof(NEW.blueprint) <> 'object' THEN
    RAISE EXCEPTION '%: a blueprint lists stats and their numbers', NEW.name;
  END IF;
  FOR v_key, v_val IN SELECT b.key, b.value FROM jsonb_each(NEW.blueprint) AS b LOOP
    v_kind := NULL;
    SELECT d.kind, coalesce(d.trainable, false) INTO v_kind, v_trainable
      FROM public.rpg_template_stat_defs(v_pkey) d WHERE d.key = v_key;
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
    FROM public.rpg_characters ch WHERE ch.agency_id = OLD.agency_id AND ch.template_key = OLD.key;
  SELECT string_agg(d.name, ', ' ORDER BY d.sort_order, d.name) INTO v_skills
    FROM public.rpg_stat_definitions d WHERE d.agency_id = OLD.agency_id AND d.template_key = OLD.key;
  IF v_kids IS NOT NULL OR v_chars > 0 OR v_skills IS NOT NULL THEN
    RAISE EXCEPTION '% cannot be deleted yet. Still made from it: %', OLD.name,
      concat_ws('; ', 'cards ' || v_kids,
                CASE WHEN v_chars > 0 THEN v_chars || CASE WHEN v_chars = 1 THEN ' character' ELSE ' characters' END END,
                'its own skills ' || v_skills);
  END IF;
  RETURN OLD;
END;
$function$;

DROP TRIGGER IF EXISTS rpg_creatures_template_check ON public.rpg_creatures;
ALTER TABLE public.rpg_creatures DROP COLUMN parent_key;
CREATE TRIGGER rpg_creatures_template_check BEFORE INSERT OR UPDATE OF parent_id, blueprint ON public.rpg_creatures
  FOR EACH ROW EXECUTE FUNCTION public.rpg_creatures_template_check();

ALTER TABLE public.rpg_creature_actions DROP COLUMN table_note;

DO $$
DECLARE v text;
BEGIN
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prokind = 'f' AND pg_get_functiondef(p.oid) ~ '(parent_key|table_note)';
  IF v IS NOT NULL THEN RAISE EXCEPTION 'still read by: %', v; END IF;
  IF NOT has_function_privilege('authenticated', 'public.rpg_creature_card(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'card lost its grant';
  END IF;
END $$;
