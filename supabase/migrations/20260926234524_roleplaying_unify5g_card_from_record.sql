-- Roleplaying unify5g: the creature card is built only from its record.
-- rpg_action_text is the one place an action's line is written (beats, energy, the roll, damage, the effect), read
-- by the card and the fight screen alike, so no hand-typed note can drift from the numbers. table_note is no longer
-- read by anything. Multiattack is deleted (Peter 2026-09-26): each action's beat cost now shows on the card.
-- A card whose parent is missing, or a card others still depend on being deleted, gets a plain message.

CREATE OR REPLACE FUNCTION public.rpg_action_text(p_action_id uuid, p_skill numeric DEFAULT NULL)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One plain line for what a card's action does, built only from its row: the beats it takes on the creature's own
-- turn (actions only; a turn has beats_per_turn), its energy, the skill it rolls against which stat × the opponent
-- multiplier, whether it does damage, and its effect. With p_skill (a fight) the line carries the creature's number:
-- "1 beat · 3 physical energy · Rolls its Claw 10 against the target's Evade Enemy × 2 and does damage. A hit also
-- rolls its Strength against the target's Strength × 2; if that lands, the target is Knocked down and cannot act
-- until their turn starts." Traits do nothing on their own, so they get no line.
DECLARE
  a        public.rpg_creature_actions%ROWTYPE;
  v_names  jsonb;
  v_m      text := trim_scale(public.rpg_setting('opponent_will_multiplier'))::text;
  v_per    numeric := public.rpg_setting('beats_per_turn');
  v_parts  text[] := '{}';
  v_fx     jsonb;
  v_ap     jsonb;
  v_fxt    text;
  v_line   text;
BEGIN
  SELECT * INTO a FROM public.rpg_creature_actions WHERE id = p_action_id;
  IF NOT FOUND OR a.kind = 'trait' THEN RETURN NULL; END IF;
  SELECT jsonb_object_agg(d.key, d.name) INTO v_names
    FROM public.rpg_stat_definitions d WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365';

  IF a.kind IN ('action', 'bonus_action') AND coalesce(a.beats, 0) > 0 THEN
    v_parts := v_parts || (a.beats || CASE WHEN a.beats = 1 THEN ' beat' ELSE ' beats' END
                           || CASE WHEN a.beats >= v_per THEN ' (the whole turn)' ELSE '' END);
  END IF;
  IF coalesce(a.energy_cost, 0) > 0 THEN
    v_parts := v_parts || (a.energy_cost || ' ' || a.energy_type || ' energy');
  END IF;
  IF a.skill_key IS NOT NULL THEN
    v_parts := v_parts || ('Rolls its ' || coalesce(v_names->>a.skill_key, a.skill_key)
                           || coalesce(' ' || trim_scale(p_skill)::text, '')
                           || ' against ' || CASE WHEN a.area THEN 'each target''s ' ELSE 'the target''s ' END
                           || coalesce(v_names->>a.against, a.against) || ' × ' || v_m
                           || CASE WHEN a.deals_damage THEN ' and does damage' ELSE '' END);
  END IF;
  v_line := array_to_string(v_parts, ' · ');

  v_fx := a.effect;
  IF v_fx IS NOT NULL AND v_fx ? 'apply' THEN
    v_ap := v_fx->'apply';
    IF v_fx->>'on' = 'self' THEN
      v_fxt := 'It is ' || (v_ap->>'name')
            || coalesce(' (' || (SELECT string_agg(coalesce(v_names->>b.k, b.k) || ' +' || b.v, ', ')
                                   FROM jsonb_each_text(v_ap->'bonus') AS b(k, v)) || ')', '')
            || CASE v_ap->>'clear' WHEN 'turn_start' THEN ' until its next turn starts'
                                   WHEN 'round' THEN ' until the next round' ELSE '' END;
    ELSE
      v_fxt := CASE
                 WHEN v_fx->>'on' = 'hit' AND v_fx ? 'contest' THEN
                   'A hit also rolls its ' || coalesce(v_names->>(v_fx->'contest'->>'skill_key'), v_fx->'contest'->>'skill_key')
                   || ' against the target''s ' || coalesce(v_names->>(v_fx->'contest'->>'against'), v_fx->'contest'->>'against')
                   || ' × ' || v_m || '; if that lands, the target is '
                 WHEN v_fx->>'on' = 'hit' THEN 'A hit also leaves the target '
                 WHEN a.area THEN 'Those it beats are '
                 ELSE 'If it beats the target, they are '
               END
            || (v_ap->>'name')
            || CASE WHEN coalesce((v_ap->>'cannot_act')::boolean, false) THEN ' and cannot act' ELSE '' END
            || CASE v_ap->>'clear'
                 WHEN 'turn_start' THEN ' until their turn starts'
                 WHEN 'round' THEN ' until the next round'
                 WHEN 'check' THEN ': on each of their turns they roll '
                                   || coalesce(v_names->>(v_ap->>'check_stat'), v_ap->>'check_stat')
                                   || ' against ' || trim_scale((v_ap->>'check_difficulty')::numeric)::text || ' to shake it off'
                                   || CASE WHEN v_ap->>'on_fail' = 'no_attack' THEN ', and if that fails they cannot attack that turn' ELSE '' END
                 ELSE '' END;
    END IF;
    v_line := CASE WHEN v_line = '' THEN v_fxt ELSE v_line || '. ' || v_fxt END;
  END IF;
  RETURN nullif(v_line, '') || CASE WHEN nullif(v_line, '') IS NULL THEN '' ELSE '.' END;
END;
$function$;
REVOKE ALL ON FUNCTION public.rpg_action_text(uuid, numeric) FROM PUBLIC, anon, authenticated;

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
        'parent_key', v_c.parent_key,
        'parent_name', (SELECT p.name FROM public.rpg_creatures p WHERE p.agency_id = v_c.agency_id AND p.key = v_c.parent_key),
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
          'skills', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', s->>'key', 'name', s->>'name', 'value', s->'value', 'own', d.template_key IS NOT NULL)
                                     ORDER BY (d.template_key IS NULL), o), '[]'::jsonb)
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

CREATE OR REPLACE FUNCTION public.rpg_creatures_template_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Parent: a card is either made from another card that exists or is a top card (no parent); it can never end up
-- above itself (Wolf under Grey Wolf under Wolf is refused).
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
BEGIN
  IF NEW.parent_key IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.rpg_creatures p WHERE p.agency_id = NEW.agency_id AND p.key = NEW.parent_key) THEN
    RAISE EXCEPTION '% cannot be made from "%": there is no card with that key. Leave the parent empty to make it a top card', NEW.name, NEW.parent_key;
  END IF;
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
    FROM public.rpg_creatures c WHERE c.agency_id = OLD.agency_id AND c.parent_key = OLD.key;
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
REVOKE ALL ON FUNCTION public.rpg_creatures_delete_check() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS rpg_creatures_delete_check ON public.rpg_creatures;
CREATE TRIGGER rpg_creatures_delete_check BEFORE DELETE ON public.rpg_creatures
  FOR EACH ROW EXECUTE FUNCTION public.rpg_creatures_delete_check();

-- Multiattack only repeated the beat costs the actions carry. Gone; the card shows each action's beats.
DELETE FROM public.rpg_creature_actions a USING public.rpg_creatures c
 WHERE c.id = a.creature_id AND c.key = 'bramblemaw' AND a.name = 'Multiattack';

-- Descriptions are the picture only. What an action does comes from its record through rpg_action_text, so no
-- description repeats a number or a rule that could drift (Hunting Screech still promised a three-turn cooldown).
UPDATE public.rpg_creature_actions a SET description = v.d
  FROM public.rpg_creatures c,
       (VALUES
        ('bramblemaw', 'Claw', 'It rakes one target with its claws.'),
        ('bramblemaw', 'Bite', 'It clamps its jaws on one target.'),
        ('bramblemaw', 'Briar Roar', 'It lets out a thunderous roar.'),
        ('bramblemaw', 'Grasping Roots', 'Vines and roots burst out of the ground.'),
        ('bramblemaw', 'Rending Swipe', 'It sweeps its claws in a wide arc.'),
        ('bramblemaw', 'Sink Into Soil', 'It sinks partly into the ground.'),
        ('ashwing_harrier', 'Hunting Screech', 'A scream that scatters prey.')
       ) AS v(card, name, d)
 WHERE c.id = a.creature_id AND c.key = v.card AND a.name = v.name;

-- Nothing reads table_note now (the card and the fight screen both use rpg_action_text).
DO $$
DECLARE v text;
BEGIN
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prokind = 'f' AND pg_get_functiondef(p.oid) ~ 'table_note';
  IF v IS NOT NULL THEN RAISE EXCEPTION 'table_note still read by: %', v; END IF;
  IF has_function_privilege('authenticated', 'public.rpg_action_text(uuid, numeric)', 'EXECUTE') THEN
    RAISE EXCEPTION 'rpg_action_text must not be callable by a login';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.rpg_creature_card(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpg_session_state(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'card or fight screen lost its grant';
  END IF;
END $$;
