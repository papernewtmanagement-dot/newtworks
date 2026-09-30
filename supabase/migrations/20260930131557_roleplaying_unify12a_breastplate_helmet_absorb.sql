-- roleplaying_unify12a_breastplate_helmet_absorb
-- Peter 2026-09-30, "Defaults" (1A 2A 3A): attacks on the heart and the mind. An armor piece says what it guards
-- (rpg_stat_definitions.guards: Shield of Faith 'block', Breastplate of Righteousness 'heart', Helmet of Salvation
-- 'mind'); a spiritual attack's card says what it aims at (effect "aim": heart or mind). A landed attack on the heart
-- or mind is absorbed by the piece that guards it, up to the piece's own value, which wears by that much (life 3 ×
-- value, like the shield); only what is left puts the effect on. Prayer and Bible Study restore the most-worn piece
-- first, leftover flowing to the next. rpg_armor_state / rpg_armor_wear are the one state and one writer for every
-- piece (the shield's two functions were only ever the SF case of them).

ALTER TABLE public.rpg_stat_definitions ADD COLUMN IF NOT EXISTS guards text;
ALTER TABLE public.rpg_stat_definitions DROP CONSTRAINT IF EXISTS rpg_stat_definitions_guards_check;
ALTER TABLE public.rpg_stat_definitions ADD CONSTRAINT rpg_stat_definitions_guards_check CHECK (guards IS NULL OR guards IN ('block', 'heart', 'mind'));
COMMENT ON COLUMN public.rpg_stat_definitions.guards IS 'An armor-of-God piece that wears (life 3 × value, wear in rpg_characters.spirit_wear): block = it blocks spiritual attacks (Shield of Faith); heart / mind = it absorbs attacks a card aims there (Breastplate of Righteousness, Helmet of Salvation).';
UPDATE public.rpg_stat_definitions SET guards = CASE key WHEN 'SF' THEN 'block' WHEN 'BR' THEN 'heart' WHEN 'HS' THEN 'mind' END
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key IN ('SF', 'BR', 'HS');

CREATE OR REPLACE FUNCTION public.rpg_armor_state(p_character_id uuid, p_key text)
 RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
  -- One armor-of-God piece's state: its value from the sheet (rpg_sheet_values), a life of 3 × its value (Shield of
  -- Faith 6: 18; Breastplate 10: 30), the wear it has taken (rpg_characters.spirit_wear->>key), what is left, and
  -- broken (nothing left: it blocks or absorbs nothing until Prayer or Bible Study restore it). Null for a stat that
  -- guards nothing. Read by rpg_act, rpg_sheet, rpg_armor_wear and rpg_discipline_effects. Internal.
  SELECT jsonb_build_object('key', d.key, 'name', d.name, 'guards', d.guards, 'value', x.v, 'life', 3 * x.v, 'wear', x.wear,
                            'left', greatest(3 * x.v - x.wear, 0), 'broken', x.wear >= 3 * x.v)
    FROM public.rpg_stat_definitions d
    JOIN public.rpg_characters c ON c.id = p_character_id
    CROSS JOIN LATERAL (SELECT coalesce((sv -> 'values' ->> d.key)::numeric, 0) AS v, coalesce((c.spirit_wear ->> d.key)::numeric, 0) AS wear
                          FROM public.rpg_sheet_values(c.id) sv) x
   WHERE d.key = p_key AND d.guards IS NOT NULL;
$function$;
REVOKE ALL ON FUNCTION public.rpg_armor_state(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpg_armor_state(uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION public.rpg_armor_wear(p_character_id uuid, p_key text, p_delta integer)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
-- Wears (+) or restores (−) one armor-of-God piece; its wear stays between 0 and its life. A shield with 18 life that
-- has taken 15 and now takes 8 → 0 left, broke; restored by 20 → 18 of 18. Returns {key, name, life, taken, restored,
-- left, broke}. Used by rpg_act (a blocked spiritual attack wears the shield; an absorbed attack on the heart or mind
-- wears the breastplate or helmet) and rpg_discipline_effects (Prayer, Bible Study). Internal.
DECLARE v_s jsonb; v_wear numeric; v_new numeric;
BEGIN
  v_s := public.rpg_armor_state(p_character_id, p_key);
  IF v_s IS NULL THEN RAISE EXCEPTION '% is not an armor piece that wears', p_key; END IF;
  v_wear := (v_s ->> 'wear')::numeric;
  v_new := least(greatest(v_wear + coalesce(p_delta, 0), 0), (v_s ->> 'life')::numeric);
  UPDATE public.rpg_characters SET spirit_wear = coalesce(spirit_wear, '{}'::jsonb) || jsonb_build_object(p_key, v_new) WHERE id = p_character_id;
  RETURN jsonb_build_object('key', p_key, 'name', v_s ->> 'name', 'life', (v_s ->> 'life')::numeric,
                            'taken', greatest(v_new - v_wear, 0), 'restored', greatest(v_wear - v_new, 0),
                            'left', (v_s ->> 'life')::numeric - v_new,
                            'broke', v_new >= (v_s ->> 'life')::numeric AND v_wear < (v_s ->> 'life')::numeric);
END;
$function$;
REVOKE ALL ON FUNCTION public.rpg_armor_wear(uuid, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpg_armor_wear(uuid, text, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.rpg_discipline_effects(p_character_id uuid, p_strength numeric)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
-- A successful Prayer or Bible Study (strength = its die minus what it needed, like a blow's damage) works off the
-- burden of sins and bad decisions by strength ÷ 10 rounded up, at least 1 (a 70 needing 50 works off 2), and restores
-- the armor of God by the strength: the most-worn piece first (by the share of its life missing), what is left flowing
-- to the next (a shield 0 of 18 and a breastplate 20 of 30, strength 20: the shield takes 18, the breastplate 2).
-- Returns {burden_before, burden_after, burden_off, armor [{key, name, restored, left, life}], text}; the text is what
-- the log and the sheet say. Called by rpg_roll. Internal.
DECLARE v_c record; v_off integer; v_after integer; v_w jsonb; v_text text := ''; v_left integer; v_p record; v_armor jsonb := '[]'::jsonb; v_parts text[] := '{}';
BEGIN
  SELECT * INTO v_c FROM public.rpg_characters WHERE id = p_character_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'character not found'; END IF;
  v_off := least(greatest(ceil(coalesce(p_strength, 0) / 10.0)::integer, 1), coalesce(v_c.spiritual_burden, 0));
  v_after := coalesce(v_c.spiritual_burden, 0) - v_off;
  IF v_off > 0 THEN
    UPDATE public.rpg_characters SET spiritual_burden = v_after WHERE id = p_character_id;
    v_text := v_c.name || '''s burden eases by ' || v_off || CASE WHEN v_after = 0 THEN ', none left.' ELSE ', ' || v_after || ' left.' END;
  END IF;
  v_left := floor(greatest(coalesce(p_strength, 0), 0))::integer;
  FOR v_p IN SELECT s.* FROM public.rpg_stat_definitions d
                 CROSS JOIN LATERAL jsonb_to_record(public.rpg_armor_state(p_character_id, d.key)) AS s(key text, name text, life numeric, wear numeric)
              WHERE d.agency_id = v_c.agency_id AND d.guards IS NOT NULL AND s.wear > 0
              ORDER BY s.wear / greatest(s.life, 1) DESC, d.sort_order LOOP
    EXIT WHEN v_left <= 0;
    v_w := public.rpg_armor_wear(p_character_id, v_p.key, -least(v_left, v_p.wear::integer));
    v_left := v_left - (v_w ->> 'restored')::numeric::integer;
    v_armor := v_armor || jsonb_build_array(jsonb_build_object('key', v_p.key, 'name', v_p.name, 'restored', v_w -> 'restored', 'left', v_w -> 'left', 'life', v_w -> 'life'));
    v_parts := v_parts || ('the ' || v_p.name || ' by ' || (v_w ->> 'restored')::numeric::integer || ', ' || (v_w ->> 'left')::numeric::integer || ' of ' || (v_w ->> 'life')::numeric::integer);
  END LOOP;
  IF cardinality(v_parts) > 0 THEN
    v_text := btrim(v_text || ' Restored: ' || array_to_string(v_parts, '; ') || '.');
  END IF;
  RETURN jsonb_build_object('burden_before', coalesce(v_c.spiritual_burden, 0), 'burden_after', v_after, 'burden_off', v_off,
                            'armor', v_armor, 'text', v_text);
END;
$function$;

-- Anchored patches.
CREATE FUNCTION pg_temp.rep(p_def text, p_old text, p_new text, p_label text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n integer := (length(p_def) - length(replace(p_def, p_old, ''))) / length(p_old);
BEGIN
  IF n <> 1 THEN RAISE EXCEPTION 'anchor % found % times', p_label, n; END IF;
  RETURN replace(p_def, p_old, p_new);
END $f$;

DO $do$
DECLARE v text; v_src text;
BEGIN
  -- rpg_act: patched by anchors; its md5 is checked first.
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_act';
  IF v_src NOT LIKE '%rpg_armor_state%' THEN
    IF md5(v_src) <> 'c14668b9c3a0a6afab7560d171123cac' THEN RAISE EXCEPTION 'rpg_act body drifted (md5 %), patch by hand', md5(v_src); END IF;
    v := pg_get_functiondef('public.rpg_act(uuid,uuid[],text,uuid,text,numeric,integer,text)'::regprocedure);
    v := pg_temp.rep(v, $a$--   lands an effect is blocked by the Shield of Faith. Fail = Blocked; the blocking item takes the blow's damage
--   (rpg_item_damage) and the weapon a fifth of it. Hit: rpg_damage minus what worn armor absorbs (the armor takes
--   that; the weapon a fifth); what is left must clear the target's Integrity. A landed effect goes on the target as$a$,
$b$--   lands an effect is blocked by the Shield of Faith. Fail = Blocked; the blocking item takes the blow's damage
--   (rpg_item_damage) and the weapon a fifth of it. Hit: rpg_damage minus what worn armor absorbs (the armor takes
--   that; the weapon a fifth); what is left must clear the target's Integrity. An attack on the heart or the mind (the
--   card's "aim") is absorbed by the armor piece that guards it (rpg_stat_definitions.guards: the Breastplate of
--   Righteousness, the Helmet of Salvation) up to its own value, which wears by that much; only what is left puts
--   the effect on (rpg_armor_state, rpg_armor_wear). A landed effect goes on the target as$b$, 'act header');
    v := pg_temp.rep(v, $a$v_discipline boolean := false; v_shield jsonb;$a$,
$b$v_discipline boolean := false; v_shield jsonb; v_piece jsonb; v_turned boolean := false; v_strength integer;$b$, 'act declare');
    v := pg_temp.rep(v, $a$          v_shield := public.rpg_shield_state(v_t.character_id);
          IF (v_shield->>'broken')::boolean THEN v_blk := NULL; ELSE v_blk := public.rpg_participant_value(v_tid, 'SF'); END IF;
          v_blocker_name := 'Shield of Faith';$a$,
$b$          v_shield := public.rpg_armor_state(v_t.character_id, (SELECT d.key FROM public.rpg_stat_definitions d WHERE d.guards = 'block' LIMIT 1));
          IF v_shield IS NULL OR (v_shield->>'broken')::boolean THEN v_blk := NULL; ELSE v_blk := public.rpg_participant_value(v_tid, v_shield->>'key'); END IF;
          v_blocker_name := coalesce(v_shield->>'name', 'Shield of Faith');$b$, 'act shield state');
    v := pg_temp.rep(v, $a$              v_wear := public.rpg_shield_wear(v_t.character_id, greatest((v_first->>'roll')::integer - v_needs, 0));
              v_tail := v_tail || ' The Shield of Faith takes ' || (v_wear->>'taken')::numeric::integer || CASE WHEN (v_wear->>'broke')::boolean THEN ' and breaks.' ELSE ', ' || (v_wear->>'left')::numeric::integer || ' left.' END;$a$,
$b$              v_wear := public.rpg_armor_wear(v_t.character_id, v_shield->>'key', greatest((v_first->>'roll')::integer - v_needs, 0));
              v_tail := v_tail || ' The ' || (v_shield->>'name') || ' takes ' || (v_wear->>'taken')::numeric::integer || CASE WHEN (v_wear->>'broke')::boolean THEN ' and breaks.' ELSE ', ' || (v_wear->>'left')::numeric::integer || ' left.' END;$b$, 'act shield wear');
    v := pg_temp.rep(v, $a$      IF v_net > 0 THEN v_vit := public.rpg_session_adjust_vitality(v_tid, v_net);
      ELSE v_vit := public.rpg_participant_vitality(v_tid); END IF;
      v_out := CASE WHEN v_blocked THEN jsonb_build_object('key', 'blocked', 'label', 'Blocked')
                    WHEN v_bounced THEN jsonb_build_object('key', 'bounced', 'label', 'Bounced off')$a$,
$b$      IF v_net > 0 THEN v_vit := public.rpg_session_adjust_vitality(v_tid, v_net);
      ELSE v_vit := public.rpg_participant_vitality(v_tid); END IF;
      -- An attack on the heart or the mind (the card's "aim"): the armor piece that guards it absorbs up to its own value
      -- of the attack's strength (the die minus what it needed) and wears by that much; only what is left puts the
      -- effect on. Zaboo's Breastplate 10 against a Briar Roar of strength 23: takes 10, 13 gets through, Frightened;
      -- strength 8: turned aside. Broken, or with no value, it absorbs nothing.
      v_turned := false;
      IF v_kind = 'action' AND v_fx->>'aim' IS NOT NULL AND v_fx->>'on' = 'land' AND v_first->>'result' <> '' AND NOT v_blocked AND v_t.character_id IS NOT NULL THEN
        v_piece := public.rpg_armor_state(v_t.character_id, (SELECT d.key FROM public.rpg_stat_definitions d WHERE d.guards = v_fx->>'aim' LIMIT 1));
        IF v_piece IS NOT NULL AND (v_piece->>'value')::numeric > 0 AND NOT (v_piece->>'broken')::boolean THEN
          v_strength := greatest((v_first->>'roll')::integer - v_needs, 0);
          v_absorb := least(floor((v_piece->>'value')::numeric)::integer, v_strength);
          v_wear := public.rpg_armor_wear(v_t.character_id, v_piece->>'key', v_absorb);
          IF v_strength - v_absorb <= 0 THEN
            v_turned := true;
            v_tail := v_tail || ' ' || v_t.name || '''s ' || (v_piece->>'name') || ' turns it aside'
                      || CASE WHEN v_absorb > 0 THEN ' (takes ' || v_absorb || CASE WHEN (v_wear->>'broke')::boolean THEN ' and breaks)' ELSE ', ' || (v_wear->>'left')::numeric::integer || ' of ' || (v_wear->>'life')::numeric::integer || ' left)' END ELSE '' END || '.';
          ELSE
            v_tail := v_tail || ' ' || v_t.name || '''s ' || (v_piece->>'name') || ' takes ' || v_absorb
                      || CASE WHEN (v_wear->>'broke')::boolean THEN ' and breaks' ELSE ', ' || (v_wear->>'left')::numeric::integer || ' of ' || (v_wear->>'life')::numeric::integer || ' left' END
                      || '; ' || (v_strength - v_absorb) || ' gets through.';
          END IF;
        END IF;
      END IF;
      v_out := CASE WHEN v_blocked THEN jsonb_build_object('key', 'blocked', 'label', 'Blocked')
                    WHEN v_turned THEN jsonb_build_object('key', 'bounced', 'label', 'Turned aside')
                    WHEN v_bounced THEN jsonb_build_object('key', 'bounced', 'label', 'Bounced off')$b$, 'act absorb gate');
    v := pg_temp.rep(v, $a$      IF v_kind = 'action' AND v_fx IS NOT NULL AND v_first->>'result' <> '' AND NOT v_blocked AND NOT v_bounced AND (v_vit->>'left')::integer > 0 THEN$a$,
$b$      IF v_kind = 'action' AND v_fx IS NOT NULL AND v_first->>'result' <> '' AND NOT v_blocked AND NOT v_bounced AND NOT v_turned AND (v_vit->>'left')::integer > 0 THEN$b$, 'act effect gate');
    EXECUTE v;
  END IF;

  -- rpg_sheet: patched by anchors; its md5 is checked first.
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_sheet';
  IF v_src NOT LIKE '%rpg_armor_state%' THEN
    IF md5(v_src) <> '28098c95ba5de219f3164f5b5a3955c9' THEN RAISE EXCEPTION 'rpg_sheet body drifted (md5 %), patch by hand', md5(v_src); END IF;
    v := pg_get_functiondef('public.rpg_sheet(uuid,numeric)'::regprocedure);
    v := pg_temp.rep(v, $a$    'spiritual_burden', coalesce(v_c.spiritual_burden, 0), 'shield', public.rpg_shield_state(p_character_id),$a$,
$b$    'spiritual_burden', coalesce(v_c.spiritual_burden, 0),
    -- the armor of God pieces that wear (rpg_stat_definitions.guards): the Shield of Faith, the Breastplate, the Helmet
    'armor', (SELECT coalesce(jsonb_agg(public.rpg_armor_state(p_character_id, d.key) ORDER BY d.sort_order), '[]'::jsonb)
                FROM public.rpg_stat_definitions d WHERE d.agency_id = v_c.agency_id AND d.guards IS NOT NULL),$b$, 'sheet armor');
    EXECUTE v;
  END IF;

  -- rpg_action_text: patched by anchors; its md5 is checked first.
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_action_text';
  IF v_src NOT LIKE '%guards%' THEN
    IF md5(v_src) <> 'b9b2f8bf34b25a7918f57440ddea97ee' THEN RAISE EXCEPTION 'rpg_action_text body drifted (md5 %), patch by hand', md5(v_src); END IF;
    v := pg_get_functiondef('public.rpg_action_text(uuid,numeric)'::regprocedure);
    v := pg_temp.rep(v, $a$                         || CASE v_ap->'on_harm'->>'exposed' WHEN 'source' THEN ': its own attacks face their Evade Enemy × 1' WHEN 'all' THEN ': every attacker faces their Evade Enemy × 1' ELSE '' END
                    ELSE '' END;$a$,
$b$                         || CASE v_ap->'on_harm'->>'exposed' WHEN 'source' THEN ': its own attacks face their Evade Enemy × 1' WHEN 'all' THEN ': every attacker faces their Evade Enemy × 1' ELSE '' END
                    ELSE '' END
            || CASE WHEN v_fx ? 'aim'
                    THEN '. An attack on the ' || (v_fx->>'aim') || ': the ' || coalesce((SELECT d.name FROM public.rpg_stat_definitions d WHERE d.guards = v_fx->>'aim' LIMIT 1), 'armor')
                         || ' absorbs up to its value of the attack''s strength first, and only what is left lands'
                    ELSE '' END;$b$, 'text aim');
    EXECUTE v;
  END IF;

  -- rpg_creature_actions_skill_check: patched by anchors; its md5 is checked first.
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_creature_actions_skill_check';
  IF v_src NOT LIKE '%guards%' THEN
    IF md5(v_src) <> 'ccdc8f03f7dd3816bb2621d4dea78f2f' THEN RAISE EXCEPTION 'rpg_creature_actions_skill_check body drifted (md5 %), patch by hand', md5(v_src); END IF;
    v := pg_get_functiondef('public.rpg_creature_actions_skill_check()'::regprocedure);
    v := pg_temp.rep(v, $a$  IF jsonb_typeof(NEW.effect->'apply'->'bonus') = 'object' THEN$a$,
$b$  -- an attack's aim (heart, mind) must be something an armor piece guards (rpg_stat_definitions.guards)
  IF NEW.effect ? 'aim' AND NOT EXISTS (SELECT 1 FROM public.rpg_stat_definitions d WHERE d.guards = NEW.effect->>'aim' AND d.guards <> 'block') THEN
    RAISE EXCEPTION '% on the % card aims at %, which no armor piece guards', NEW.name, v_name, NEW.effect->>'aim';
  END IF;
  IF jsonb_typeof(NEW.effect->'apply'->'bonus') = 'object' THEN$b$, 'trigger aim');
    EXECUTE v;
  END IF;

  -- rpg_roll: patched by anchors; its md5 is checked first.
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_roll';
  IF v_src NOT LIKE '%restores the armor of God%' THEN
    IF md5(v_src) <> '910c0fb70f5266437034a91ba4d88dae' THEN RAISE EXCEPTION 'rpg_roll body drifted (md5 %), patch by hand', md5(v_src); END IF;
    v := pg_get_functiondef('public.rpg_roll(uuid,text,numeric,text,uuid,uuid,uuid,integer)'::regprocedure);
    v := pg_temp.rep(v, $a$  -- a successful Prayer or Bible Study eases the burden and restores the Shield of Faith (rpg_discipline_effects)$a$,
$b$  -- a successful Prayer or Bible Study eases the burden and restores the armor of God, most-worn piece first (rpg_discipline_effects)$b$, 'roll comment');
    EXECUTE v;
  END IF;

END $do$;

-- The cards say what each spiritual attack aims at. Heart: fear and dread. Mind: deceit and accusation.
UPDATE public.rpg_creature_actions a SET effect = a.effect || jsonb_build_object('aim', x.aim)
  FROM (VALUES ('Briar Roar', 'heart'), ('Hunting Screech', 'heart'), ('Lure', 'mind'), ('Judging Gaze', 'mind'), ('Living Silence', 'mind')) AS x(name, aim)
 WHERE a.name = x.name AND a.kind <> 'trait' AND a.energy_type = 'spiritual' AND a.effect ? 'apply';

-- Rule cards (the manual page follows by trigger).
DO $do$
DECLARE v text;
BEGIN
  SELECT body INTO v FROM public.rpg_rules WHERE key = 'attack_gates';
  v := pg_temp.rep(v, $a$Anything worn absorbs its own Integrity (Toughness ÷ 5) first and takes that much itself (spiritually the Breastplate of Righteousness for attacks on the heart such as fear, the Helmet of Salvation for attacks on the mind such as lies). What is left$a$,
                      $b$Anything worn absorbs its own Integrity (Toughness ÷ 5) first and takes that much itself. What is left$b$, 'gates para 3');
  v := v || E'\n\nAn attack on the heart (fear and dread: Briar Roar, Hunting Screech) or on the mind (deceit and accusation: Lure, Judging Gaze, Living Silence) says so on its card. Once it lands and gets past the Shield of Faith, the piece that guards that place absorbs it: the Breastplate of Righteousness for the heart, the Helmet of Salvation for the mind. The piece takes the attack''s strength (die − Needed) up to its own value and wears by that much (life 3 × value); only what is left puts the effect on. Broken, it absorbs nothing until Prayer or Bible Study restore it.\n*Zaboo''s Breastplate of Righteousness 10 has 30 life. A Briar Roar lands with a 90 needing 67: strength 23, the breastplate takes 10 (20 of 30 left), 13 gets through, Zaboo is Frightened. A 70 needing 67: strength 3, turned aside, 17 of 30 left.*';
  UPDATE public.rpg_rules SET body = v WHERE key = 'attack_gates';

  SELECT body INTO v FROM public.rpg_rules WHERE key = 'spirit_loop';
  v := pg_temp.rep(v, $a$and restores the Shield of Faith by die − Needed.
*A 70 needing 50 works off 2 burden and restores 20 to the Shield of Faith.*$a$,
                      $b$and restores the armor of God by die − Needed: the most-worn piece first (by the share of its life missing), what is left flowing to the next.
*A 70 needing 50 works off 2 burden and restores 20: a Shield of Faith at 0 of 18 takes 18, and a Breastplate at 20 of 30 takes the other 2.*$b$, 'spirit loop restore');
  UPDATE public.rpg_rules SET body = v WHERE key = 'spirit_loop';
END $do$;

