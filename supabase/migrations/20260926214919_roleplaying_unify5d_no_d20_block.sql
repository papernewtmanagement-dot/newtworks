-- No d20 stat block anywhere (Peter 2026-09-26). The printed d20 numbers on the creature cards and actions are
-- deleted: they drove nothing. Speed and size go too; movement will follow the one rulebook, not a creature-only stat.
CREATE OR REPLACE FUNCTION public.rpg_creature_list()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The Creatures tab list. Players see a card once it is shown to them; the game master also sees whether it is shown.
SELECT public.require_login('family');
  WITH gm AS (SELECT public.family_is_parent() AS is_gm)
  SELECT coalesce(jsonb_agg(
           jsonb_build_object('id', c.id, 'key', c.key, 'name', c.name, 'color', c.color, 'epigraph', c.epigraph)
           || CASE WHEN gm.is_gm THEN jsonb_build_object('shown_to_players', c.shown_to_players) ELSE '{}'::jsonb END
           ORDER BY c.sort_order, c.name), '[]'::jsonb)
  FROM public.rpg_creatures c CROSS JOIN gm
  WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active
    AND (SELECT public.rpg_can_play()) AND (gm.is_gm OR c.shown_to_players);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_creature_card(p_creature_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One creature card. Players get it once it is shown to them, and then only its names, haunts, epigraph, lore and
-- picture. The game master also gets how a creature is made from the card (template), each action with the skill it
-- rolls from the creature's own sheet (skill_key) and the stat the target defends with, the lair and legendary text,
-- the rumor table and the tip. Every creature's numbers are on the sheet it is made with in a fight.
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
    'legendary_per_round', v_c.legendary_per_round,
    'legendary_intro', v_c.legendary_intro,
    'lair_title', v_c.lair_title,
    'lair_intro', v_c.lair_intro,
    'rumor_title', v_c.rumor_title,
    'rumor_intro', v_c.rumor_intro,
    'rumors', v_c.rumors,
    'rumor_note', v_c.rumor_note,
    'gm_tip', v_c.gm_tip,
    -- A roll against someone who can act faces their stat × this (rpg_difficulty): Evade Enemy 5 → difficulty 10.
    'opponent_multiplier', public.rpg_setting('opponent_will_multiplier'),
    -- How a character made from this card is rolled: its parent card, and its whole blueprint (its own entries and
    -- what it takes from the cards above it), a set number (a boss) or experience points spent up the level ladder
    -- (from_1 and from_top: where those points take a 1 and start_top, the top of that stat's own roll). Anything
    -- left out rolls the standard way.
    'template', jsonb_build_object(
        'parent_key', v_c.parent_key,
        'parent_name', (SELECT p.name FROM public.rpg_creatures p WHERE p.agency_id = v_c.agency_id AND p.key = v_c.parent_key),
        'entries', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'key', d.key, 'name', d.name,
                        'fixed',   CASE WHEN jsonb_typeof(b.value) = 'number' THEN (b.value #>> '{}')::numeric END,
                        'divisor', CASE WHEN jsonb_typeof(b.value) = 'object' THEN (b.value ->> 'divisor')::numeric END, 'top', CASE WHEN jsonb_typeof(b.value) = 'object' AND (b.value ? 'divisor') THEN ceil(public.rpg_setting('strength_roll_max') / greatest((b.value ->> 'divisor')::numeric, 1)) END, 'points', CASE WHEN jsonb_typeof(b.value) = 'object' THEN (b.value ->> 'points')::numeric END, 'from_1', CASE WHEN jsonb_typeof(b.value) = 'object' THEN (SELECT c.level FROM public.rpg_climb_levels(1, (b.value ->> 'points')::numeric) c) END, 'start_top', CASE WHEN jsonb_typeof(b.value) = 'object' AND (b.value ? 'points') THEN CASE WHEN b.value ? 'divisor' THEN ceil(public.rpg_setting('strength_roll_max') / greatest((b.value ->> 'divisor')::numeric, 1)) ELSE ceil(public.rpg_setting('strength_roll_max') / public.rpg_setting('strength_roll_divisor')) END END, 'from_top', CASE WHEN jsonb_typeof(b.value) = 'object' AND (b.value ? 'points') THEN (SELECT c.level FROM public.rpg_climb_levels(CASE WHEN b.value ? 'divisor' THEN ceil(public.rpg_setting('strength_roll_max') / greatest((b.value ->> 'divisor')::numeric, 1)) ELSE ceil(public.rpg_setting('strength_roll_max') / public.rpg_setting('strength_roll_divisor')) END::integer, (b.value ->> 'points')::numeric) c) END,
                        'inherited', NOT (v_c.blueprint ? d.key))
                      ORDER BY d.sort_order, d.key), '[]'::jsonb)
                      FROM jsonb_each(public.rpg_template_blueprint(v_c.key)) AS b
                      JOIN public.rpg_template_stat_defs(v_c.key) d ON d.key = b.key),
        'die', public.rpg_setting('strength_roll_max'),
        'divisor', public.rpg_setting('strength_roll_divisor')),
    'actions', (SELECT coalesce(jsonb_agg(jsonb_build_object(
        'id', a.id, 'kind', a.kind, 'name', a.name,
        'heading', a.name
            || CASE WHEN a.kind = 'legendary' AND a.legendary_cost > 1 THEN ' (Costs ' || a.legendary_cost || ' Actions)' ELSE '' END,
        'description', a.description,
        'skill_key', a.skill_key,
        'skill_name', (SELECT d.name FROM public.rpg_stat_definitions d
                        WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND d.key = a.skill_key),
        'against', a.against,
        'against_name', (SELECT d.name FROM public.rpg_stat_definitions d
                          WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND d.key = a.against),
        'table_note', a.table_note,
        'legendary_cost', a.legendary_cost, 'makes_attacks', a.makes_attacks)
      ORDER BY array_position(ARRAY['trait','action','bonus_action','reaction','legendary','lair'], a.kind), a.sort_order), '[]'::jsonb)
      FROM public.rpg_creature_actions a WHERE a.creature_id = v_c.id));
END;
$function$;

ALTER TABLE public.rpg_creatures
  DROP COLUMN IF EXISTS armor_class, DROP COLUMN IF EXISTS armor_note, DROP COLUMN IF EXISTS hit_points, DROP COLUMN IF EXISTS hit_dice,
  DROP COLUMN IF EXISTS str_score, DROP COLUMN IF EXISTS dex_score, DROP COLUMN IF EXISTS con_score, DROP COLUMN IF EXISTS int_score,
  DROP COLUMN IF EXISTS wis_score, DROP COLUMN IF EXISTS cha_score, DROP COLUMN IF EXISTS saving_throws, DROP COLUMN IF EXISTS skills,
  DROP COLUMN IF EXISTS damage_vulnerabilities, DROP COLUMN IF EXISTS damage_resistances, DROP COLUMN IF EXISTS damage_immunities,
  DROP COLUMN IF EXISTS condition_immunities, DROP COLUMN IF EXISTS senses, DROP COLUMN IF EXISTS languages,
  DROP COLUMN IF EXISTS challenge, DROP COLUMN IF EXISTS xp, DROP COLUMN IF EXISTS alignment, DROP COLUMN IF EXISTS size,
  DROP COLUMN IF EXISTS creature_type, DROP COLUMN IF EXISTS speed_ft, DROP COLUMN IF EXISTS burrow_ft, DROP COLUMN IF EXISTS climb_ft,
  DROP COLUMN IF EXISTS fly_ft, DROP COLUMN IF EXISTS swim_ft;
ALTER TABLE public.rpg_creature_actions
  DROP COLUMN IF EXISTS to_hit, DROP COLUMN IF EXISTS save_dc, DROP COLUMN IF EXISTS save_ability,
  DROP COLUMN IF EXISTS recharge_min, DROP COLUMN IF EXISTS reach_ft, DROP COLUMN IF EXISTS range_text;

UPDATE public.rpg_rules SET body = replace(body,
  E'\n\nThe d20 stat block printed on a card (armor class, hit points, saving throws, +to hit, DCs) is kept for reading and flavor. It does not drive any roll.', '')
 WHERE key = 'creature_conversion';

