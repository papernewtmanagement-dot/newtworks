-- roleplaying_unify14_knowledge_skills (Peter 2026-10-01, "Defaults" = 1A 2A 3A)
-- Knowledge skills: one trainable skill per card ("Knowing Bramblemaw"), built on the parent card's knowledge plus its
-- own levels, so the card tree is the knowledge tree (Knowing Creature and Knowing Object are the roots). It counts on
-- both sides of every roll at a being (the roller's skill, the target's defense before the × 2) and grows by studying
-- (rolling it) and by meeting (a weight-1 share of every roll at a being of that card). Nothing changes until someone
-- studies or fights: every knowledge is 0 today.

ALTER TABLE public.rpg_stat_definitions ADD COLUMN IF NOT EXISTS knows_id uuid REFERENCES public.rpg_creatures(id) ON DELETE CASCADE;
CREATE INDEX IF NOT EXISTS rpg_stat_definitions_knows_id_idx ON public.rpg_stat_definitions (knows_id);
ALTER TABLE public.rpg_rolls ADD COLUMN IF NOT EXISTS card_id uuid REFERENCES public.rpg_creatures(id) ON DELETE SET NULL;
ALTER TABLE public.rpg_stat_definitions DROP CONSTRAINT IF EXISTS rpg_stat_definitions_grp_check;
ALTER TABLE public.rpg_stat_definitions ADD CONSTRAINT rpg_stat_definitions_grp_check
  CHECK (grp = ANY (ARRAY['strength'::text, 'mind'::text, 'physical'::text, 'derived'::text, 'spiritual'::text, 'ability'::text, 'fighting'::text, 'basic'::text, 'knowledge'::text]));

-- A being's usable knowledge of a card. Internal.
CREATE OR REPLACE FUNCTION public.rpg_knows(p_character_id uuid, p_card uuid) RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
-- A being's usable knowledge of a card: the value of its Knowing <card> stat (rpg_stat_definitions.knows_id) when the
-- skill tree says that stat is open (rpg_skill_tree), else 0. rpg_roll adds it to the roller's skill for a roll at a
-- thing of that card; rpg_act adds the target's knowledge of the actor's card to what the target defends with.
-- Karen with Knowing Bramblemaw 3 swings her Sword 8 as 11 at a Bramblemaw. Internal: revoked from logins.
DECLARE v_c record; v_key text; v_vals jsonb;
BEGIN
  IF p_character_id IS NULL OR p_card IS NULL THEN RETURN 0; END IF;
  SELECT * INTO v_c FROM public.rpg_characters WHERE id = p_character_id;
  IF NOT FOUND THEN RETURN 0; END IF;
  SELECT d.key INTO v_key FROM public.rpg_template_stat_defs(v_c.template_id) d WHERE d.knows_id = p_card;
  IF v_key IS NULL THEN RETURN 0; END IF;
  v_vals := public.rpg_sheet_values(p_character_id) -> 'values';
  IF coalesce((public.rpg_skill_tree(v_c.template_id, v_vals) -> v_key ->> 'open')::boolean, false) THEN
    RETURN coalesce((v_vals ->> v_key)::numeric, 0);
  END IF;
  RETURN 0;
END $fn$;
REVOKE ALL ON FUNCTION public.rpg_knows(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_knows(uuid, uuid) TO service_role;

-- Every card has a knowledge skill, kept by trigger.
CREATE OR REPLACE FUNCTION public.rpg_knowledge_stat_sync() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
-- Every card has one knowledge skill (Peter 2026-10-01, decision 1A): key know_<card key>, name "Knowing <card name>",
-- grp knowledge, trainable, on the Creature template (every creature and human can learn it, no object can), built on
-- the parent card's knowledge plus its own levels ({div 1, parts [[know_<parent>, 1]]}; a top card's is a root with no
-- parts). Made when a card is made, renamed with the card, re-pointed when its parent moves, and gone with the card
-- (knows_id cascades; rpg_stat_definitions_delete_cleanup drops the banks). The stat key never changes once made.
DECLARE v_creature uuid; v_parent_key text; v_formula jsonb;
BEGIN
  IF NEW.key = 'creature' THEN v_creature := NEW.id;
  ELSE SELECT id INTO v_creature FROM public.rpg_creatures WHERE agency_id = NEW.agency_id AND key = 'creature'; END IF;
  IF v_creature IS NULL THEN RETURN NEW; END IF;
  IF NEW.parent_id IS NOT NULL THEN
    SELECT d.key INTO v_parent_key FROM public.rpg_stat_definitions d WHERE d.agency_id = NEW.agency_id AND d.knows_id = NEW.parent_id;
    IF v_parent_key IS NULL THEN RAISE EXCEPTION 'the card above % has no knowledge skill yet', NEW.name; END IF;
  END IF;
  v_formula := CASE WHEN v_parent_key IS NULL THEN '{"div": 1, "parts": []}'::jsonb
                    ELSE jsonb_build_object('div', 1, 'parts', jsonb_build_array(jsonb_build_array(v_parent_key, 1))) END;
  IF EXISTS (SELECT 1 FROM public.rpg_stat_definitions d WHERE d.knows_id = NEW.id) THEN
    UPDATE public.rpg_stat_definitions SET name = 'Knowing ' || NEW.name, formula = v_formula, sort_order = 1000 + NEW.sort_order + 2, template_id = v_creature
     WHERE knows_id = NEW.id;
  ELSE
    INSERT INTO public.rpg_stat_definitions (agency_id, key, name, abbr, grp, kind, trainable, formula, default_value, sort_order,
                                             is_attack, beats, energy_cost, energy_type, reach, spirit_discipline, template_id, knows_id)
    VALUES (NEW.agency_id, 'know_' || NEW.key, 'Knowing ' || NEW.name, NULL, 'knowledge', 'derived', true, v_formula, 0, 1000 + NEW.sort_order + 2,
            false, 2, 0, 'physical', 1, false, v_creature, NEW.id);
  END IF;
  RETURN NEW;
END $fn$;
DROP TRIGGER IF EXISTS rpg_creatures_knowledge_sync ON public.rpg_creatures;
CREATE TRIGGER rpg_creatures_knowledge_sync AFTER INSERT OR UPDATE OF key, name, parent_id, sort_order ON public.rpg_creatures
  FOR EACH ROW EXECUTE FUNCTION public.rpg_knowledge_stat_sync();

CREATE OR REPLACE FUNCTION public.rpg_stat_definitions_delete_cleanup() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
-- A stat that is gone takes its banks with it (rpg_character_skills has no key to rpg_stat_definitions), so a deleted
-- card's Knowing <card> leaves no orphan rows.
BEGIN
  DELETE FROM public.rpg_character_skills WHERE stat_key = OLD.key;
  RETURN OLD;
END $fn$;
DROP TRIGGER IF EXISTS rpg_stat_definitions_delete_cleanup ON public.rpg_stat_definitions;
CREATE TRIGGER rpg_stat_definitions_delete_cleanup AFTER DELETE ON public.rpg_stat_definitions
  FOR EACH ROW EXECUTE FUNCTION public.rpg_stat_definitions_delete_cleanup();

-- the 29 cards of today, tops first so each child finds the knowledge above it
UPDATE public.rpg_creatures SET name = name WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND parent_id IS NULL;
UPDATE public.rpg_creatures SET name = name WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND parent_id IN (SELECT id FROM public.rpg_creatures WHERE parent_id IS NULL);
UPDATE public.rpg_creatures SET name = name WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND parent_id IN (SELECT c.id FROM public.rpg_creatures c JOIN public.rpg_creatures p ON p.id = c.parent_id WHERE p.parent_id IS NULL);

DO $do$
DECLARE v text; a text[]; b text[]; i integer; n integer;
BEGIN
  v := pg_get_functiondef('public.rpg_section(text)'::regprocedure);
  a := ARRAY[
    $a$WHEN 'derived' THEN 'Derived' WHEN 'basic' THEN 'Basic' ELSE 'Skills' END;$a$,
    $a$-- together in Skills. Basics are hidden rows: they show only inside a skill's parents.$a$];
  b := ARRAY[
    $a$WHEN 'derived' THEN 'Derived' WHEN 'basic' THEN 'Basic' WHEN 'knowledge' THEN 'Knowledge' ELSE 'Skills' END;$a$,
    $a$-- together in Skills. Basics are hidden rows: they show only inside a skill's parents. Knowledge of a card
  -- (rpg_stat_definitions.knows_id: Knowing Bramblemaw) sits in Knowledge.$a$];
  FOR i IN 1..array_length(a, 1) LOOP
    n := (length(v) - length(replace(v, a[i], ''))) / length(a[i]);
    IF n <> 1 THEN RAISE EXCEPTION 'rpg_section: anchor % found % times', i, n; END IF;
    v := replace(v, a[i], b[i]);
  END LOOP;
  
  EXECUTE v;
  
END $do$;

DO $do$
DECLARE v text; a text[]; b text[]; i integer; n integer;
BEGIN
  v := pg_get_functiondef('public.rpg_sheet_mix(uuid, jsonb)'::regprocedure);
  a := ARRAY[
    $a$v_frac := v_frac || jsonb_build_object(v_d.key, CASE WHEN v_d.energy_type = 'spiritual' THEN '[1,0,0]'::jsonb ELSE '[0,0,1]'::jsonb END);$a$,
    $a$-- (Swing arm physical → Body, Stillness spiritual → Spirit). When every part is 0 the weights alone decide.$a$];
  b := ARRAY[
    $a$v_frac := v_frac || jsonb_build_object(v_d.key, CASE WHEN v_d.grp = 'knowledge' THEN '[0,1,0]'::jsonb WHEN v_d.energy_type = 'spiritual' THEN '[1,0,0]'::jsonb ELSE '[0,0,1]'::jsonb END);$a$,
    $a$-- (Swing arm physical → Body, Stillness spiritual → Spirit); a knowledge root (Knowing Creature) is Mind. When every
-- part is 0 the weights alone decide.$a$];
  FOR i IN 1..array_length(a, 1) LOOP
    n := (length(v) - length(replace(v, a[i], ''))) / length(a[i]);
    IF n <> 1 THEN RAISE EXCEPTION 'rpg_sheet_mix: anchor % found % times', i, n; END IF;
    v := replace(v, a[i], b[i]);
  END LOOP;
  
  EXECUTE v;
  
END $do$;

DO $do$
DECLARE v text; a text[]; b text[]; i integer; n integer;
BEGIN
  v := pg_get_functiondef('public.rpg_trickle(uuid, text, numeric)'::regprocedure);
  a := ARRAY[
    $a$p_points numeric)$a$,
    $a$-- Returns {stat: value after} for every stat that climbed. Called by rpg_roll after the roll's own points.$a$,
    $a$v_n      integer := 0;$a$,
    $a$v_parts := coalesce(v_defs -> v_key -> 'formula' -> 'parts', '[]'::jsonb) || coalesce(v_defs -> v_key -> 'formula' -> 'plus', '[]'::jsonb);$a$];
  b := ARRAY[
    $a$p_points numeric, p_extra jsonb DEFAULT '[]'::jsonb)$a$,
    $a$-- p_extra lists more weight-1 parts for the rolled skill only: rpg_roll passes the roller's knowledge of what the roll
-- was at (Knowing Bramblemaw), so a swing at a Bramblemaw feeds that knowledge like one more basic.
-- Returns {stat: value after} for every stat that climbed. Called by rpg_roll after the roll's own points.$a$,
    $a$v_n      integer := 0;
  v_first  boolean := true;$a$,
    $a$v_parts := coalesce(v_defs -> v_key -> 'formula' -> 'parts', '[]'::jsonb) || coalesce(v_defs -> v_key -> 'formula' -> 'plus', '[]'::jsonb)
               || CASE WHEN v_first THEN coalesce(p_extra, '[]'::jsonb) ELSE '[]'::jsonb END;
    v_first := false;$a$];
  FOR i IN 1..array_length(a, 1) LOOP
    n := (length(v) - length(replace(v, a[i], ''))) / length(a[i]);
    IF n <> 1 THEN RAISE EXCEPTION 'rpg_trickle: anchor % found % times', i, n; END IF;
    v := replace(v, a[i], b[i]);
  END LOOP;
  DROP FUNCTION public.rpg_trickle(uuid, text, numeric);
  EXECUTE v;
  REVOKE ALL ON FUNCTION public.rpg_trickle(uuid, text, numeric, jsonb) FROM PUBLIC, anon, authenticated;
  GRANT EXECUTE ON FUNCTION public.rpg_trickle(uuid, text, numeric, jsonb) TO service_role;
END $do$;

DO $do$
DECLARE v text; a text[]; b text[]; i integer; n integer;
BEGIN
  v := pg_get_functiondef('public.rpg_roll(uuid, text, numeric, text, uuid, uuid, uuid, integer)'::regprocedure);
  a := ARRAY[
    $a$p_roll integer DEFAULT NULL::integer)$a$,
    $a$-- every stat that climbed a level from that (Karen's Footwork reaching 1, her Sword reading 7).$a$,
    $a$v_trainable boolean := false; v_over integer := 0;$a$,
    $a$  v_skill := greatest(v_skill - v_over, 0);
$a$,
    $a$v_grew := public.rpg_trickle(p_character_id, p_stat_key, v_points);$a$,
    $a$extra_pending, label, manual)$a$,
    $a$p_parent_roll_id, v_result = 'C', p_label, p_roll IS NOT NULL)$a$,
    $a$'bulk_over', v_over,$a$];
  b := ARRAY[
    $a$p_roll integer DEFAULT NULL::integer, p_card uuid DEFAULT NULL::uuid)$a$,
    $a$-- every stat that climbed a level from that (Karen's Footwork reaching 1, her Sword reading 7).
-- p_card is what the roll is at or about (a target's card, or a card being studied): the roller's knowledge of it
-- (rpg_knows: Knowing Bramblemaw 3) adds to the skill for this roll, and the trickle feeds that knowledge as one more
-- weight-1 part. Rolling a knowledge skill about its own card is plain study: nothing added, nothing doubled.$a$,
    $a$v_trainable boolean := false; v_over integer := 0; v_know numeric := 0; v_know_key text; v_know_name text;$a$,
    $a$  v_skill := greatest(v_skill - v_over, 0);
  -- knowledge of what the roll is at (rpg_knows): the roller's Knowing <card> adds to the skill for this roll; the level climbed from is still the sheet's
  IF p_card IS NOT NULL THEN
    SELECT d.key, d.name INTO v_know_key, v_know_name FROM public.rpg_characters c CROSS JOIN LATERAL public.rpg_template_stat_defs(c.template_id) d
     WHERE c.id = p_character_id AND d.knows_id = p_card;
    IF v_know_key = p_stat_key THEN v_know_key := NULL; v_know_name := NULL; END IF;
    IF v_know_key IS NOT NULL THEN v_know := public.rpg_knows(p_character_id, p_card); v_skill := v_skill + v_know; END IF;
  END IF;
$a$,
    $a$v_grew := public.rpg_trickle(p_character_id, p_stat_key, v_points, CASE WHEN v_know_key IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(jsonb_build_array(v_know_key, 1)) END);$a$,
    $a$extra_pending, label, manual, card_id)$a$,
    $a$p_parent_roll_id, v_result = 'C', p_label, p_roll IS NOT NULL, p_card)$a$,
    $a$'bulk_over', v_over, 'card_id', p_card, 'knowledge', CASE WHEN v_know_key IS NULL THEN NULL ELSE jsonb_build_object('key', v_know_key, 'name', v_know_name, 'value', v_know) END,$a$];
  FOR i IN 1..array_length(a, 1) LOOP
    n := (length(v) - length(replace(v, a[i], ''))) / length(a[i]);
    IF n <> 1 THEN RAISE EXCEPTION 'rpg_roll: anchor % found % times', i, n; END IF;
    v := replace(v, a[i], b[i]);
  END LOOP;
  DROP FUNCTION public.rpg_roll(uuid, text, numeric, text, uuid, uuid, uuid, integer);
  EXECUTE v;
  REVOKE ALL ON FUNCTION public.rpg_roll(uuid, text, numeric, text, uuid, uuid, uuid, integer, uuid) FROM PUBLIC, anon;
  GRANT EXECUTE ON FUNCTION public.rpg_roll(uuid, text, numeric, text, uuid, uuid, uuid, integer, uuid) TO authenticated, service_role;
END $do$;

DO $do$
DECLARE v text; a text[]; b text[]; i integer; n integer;
BEGIN
  v := pg_get_functiondef('public.rpg_roll_extra(uuid, integer)'::regprocedure);
  a := ARRAY[
    $a$v_p.participant_id, p_roll);$a$,
    $a$-- by hand.$a$];
  b := ARRAY[
    $a$v_p.participant_id, p_roll, v_p.card_id);$a$,
    $a$-- by hand. The card the first roll was at (rpg_rolls.card_id) carries over, so its knowledge counts again.$a$];
  FOR i IN 1..array_length(a, 1) LOOP
    n := (length(v) - length(replace(v, a[i], ''))) / length(a[i]);
    IF n <> 1 THEN RAISE EXCEPTION 'rpg_roll_extra: anchor % found % times', i, n; END IF;
    v := replace(v, a[i], b[i]);
  END LOOP;
  
  EXECUTE v;
  
END $do$;

DO $do$
DECLARE v text; a text[]; b text[]; i integer; n integer;
BEGIN
  v := pg_get_functiondef('public.rpg_act(uuid, uuid[], text, uuid, text, numeric, integer, text)'::regprocedure);
  a := ARRAY[
    $a$p_effect text DEFAULT NULL::text)$a$,
    $a$--   (rpg_difficulty; evade lowered by rpg_participant_burden). Under the still-target line is a Miss, above it Evaded.$a$,
    $a$v_actor record; v_s record; v_act record; v_use record; v_t record; v_item record;$a$,
    $a$SELECT * INTO v_actor FROM public.rpg_session_participants WHERE id = p_actor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;$a$,
    $a$v_roll := public.rpg_roll(v_actor.character_id, v_key, v_diff, v_label, NULL, v_s.id, p_actor_id, p_roll);$a$,
    $a$SELECT * INTO v_t FROM public.rpg_session_participants WHERE id = v_tid;
      v_defending := EXISTS (SELECT 1 FROM jsonb_array_elements(v_t.effects) e WHERE coalesce((e->>'defend')::boolean, false));$a$,
    $a$ELSE 0 END, 0);
      v_diff := public.rpg_difficulty(v_def, public.rpg_participant_can_act(v_tid)$a$,
    $a$CASE WHEN jsonb_array_length(v_plan) = 1 THEN p_roll END);$a$,
    $a$IF v_blocker IS NOT NULL THEN v_blk := coalesce(public.rpg_participant_value(v_tid, 'BLK'), 0) + coalesce(v_blk, 0); END IF;$a$,
    $a$ELSE v_blk := public.rpg_participant_value(v_tid, v_shield->>'key'); END IF;$a$,
    $a$v_label || ' (block)', NULL, v_s.id, p_actor_id);$a$,
    $a$v_cdiff := public.rpg_difficulty(coalesce(public.rpg_participant_value(v_tid, v_fx->'contest'->>'against'), 0), public.rpg_participant_can_act(v_tid), v_defending);$a$,
    $a$v_use.name || ' (' || (v_fx->'apply'->>'name') || ')', NULL, v_s.id, p_actor_id);$a$,
    $a$      -- Built with IF, not CASE: PL/pgSQL plans every CASE branch, and v_use is only assigned for a card action.
      IF v_kind = 'attack' THEN$a$,
    $a$' over: rolls as ' || trim_scale((v_first->>'skill')::numeric) || ')' ELSE '' END;$a$,
    $a$|| ' at ' || v_t.name || CASE WHEN v_damage_ok THEN '' ELSE ' (' || v_against_name || ')' END;$a$,
    $a$v_who := v_actor.name || ' rolls ' || v_label || ' against ' || v_t.name || '''s ' || v_against_name;$a$,
    $a$|| ' rolls ' || v_label || ' against ' || trim_scale(v_diff) || CASE WHEN v_discipline$a$];
  b := ARRAY[
    $a$p_effect text DEFAULT NULL::text, p_card uuid DEFAULT NULL::uuid)$a$,
    $a$--   (rpg_difficulty; evade lowered by rpg_participant_burden). Under the still-target line is a Miss, above it Evaded.
--   Knowledge (rpg_knows) counts both ways: the actor's Knowing <the target's card> goes into rpg_roll, the target's
--   Knowing <the actor's card> adds to the stat it defends with (evade, block, a contest) before the × 2, and the log
--   names both. p_card is the card a no-target check is about (studying a Bramblemaw).$a$,
    $a$v_actor record; v_s record; v_act record; v_use record; v_t record; v_item record; v_actor_card uuid; v_target_card uuid; v_know_def numeric := 0; v_know_txt text := '';$a$,
    $a$SELECT * INTO v_actor FROM public.rpg_session_participants WHERE id = p_actor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  SELECT template_id INTO v_actor_card FROM public.rpg_characters WHERE id = v_actor.character_id;$a$,
    $a$v_roll := public.rpg_roll(v_actor.character_id, v_key, v_diff, v_label, NULL, v_s.id, p_actor_id, p_roll, p_card);$a$,
    $a$SELECT * INTO v_t FROM public.rpg_session_participants WHERE id = v_tid;
      v_defending := EXISTS (SELECT 1 FROM jsonb_array_elements(v_t.effects) e WHERE coalesce((e->>'defend')::boolean, false));
      -- knowledge both ways (rpg_knows): the target's Knowing <the actor's card> adds to what it defends with; the actor's Knowing <the target's card> goes into rpg_roll
      SELECT template_id INTO v_target_card FROM public.rpg_characters WHERE id = v_t.character_id;
      v_know_def := public.rpg_knows(v_t.character_id, v_actor_card);$a$,
    $a$ELSE 0 END, 0) + v_know_def;
      v_diff := public.rpg_difficulty(v_def, public.rpg_participant_can_act(v_tid)$a$,
    $a$CASE WHEN jsonb_array_length(v_plan) = 1 THEN p_roll END, v_target_card);$a$,
    $a$IF v_blocker IS NOT NULL THEN v_blk := coalesce(public.rpg_participant_value(v_tid, 'BLK'), 0) + coalesce(v_blk, 0) + v_know_def; END IF;$a$,
    $a$ELSE v_blk := public.rpg_participant_value(v_tid, v_shield->>'key') + v_know_def; END IF;$a$,
    $a$v_label || ' (block)', NULL, v_s.id, p_actor_id, NULL, v_target_card);$a$,
    $a$v_cdiff := public.rpg_difficulty(coalesce(public.rpg_participant_value(v_tid, v_fx->'contest'->>'against'), 0) + v_know_def, public.rpg_participant_can_act(v_tid), v_defending);$a$,
    $a$v_use.name || ' (' || (v_fx->'apply'->>'name') || ')', NULL, v_s.id, p_actor_id, NULL, v_target_card);$a$,
    $a$      -- knowledge in the log: "(Knowing Bramblemaw 3; Bramblemaw 2 knows Human 2)"
      v_know_txt := concat_ws('; ',
        CASE WHEN coalesce((v_first->'knowledge'->>'value')::numeric, 0) > 0 THEN (v_first->'knowledge'->>'name') || ' ' || trim_scale((v_first->'knowledge'->>'value')::numeric) END,
        CASE WHEN v_know_def > 0 THEN v_t.name || ' knows ' || (SELECT k.name FROM public.rpg_creatures k WHERE k.id = v_actor_card) || ' ' || trim_scale(v_know_def) END);
      v_know_txt := CASE WHEN v_know_txt <> '' THEN ' (' || v_know_txt || ')' ELSE '' END;
      -- Built with IF, not CASE: PL/pgSQL plans every CASE branch, and v_use is only assigned for a card action.
      IF v_kind = 'attack' THEN$a$,
    $a$' over: rolls as ' || trim_scale((v_first->>'skill')::numeric) || ')' ELSE '' END || v_know_txt;$a$,
    $a$|| ' at ' || v_t.name || CASE WHEN v_damage_ok THEN '' ELSE ' (' || v_against_name || ')' END || v_know_txt;$a$,
    $a$v_who := v_actor.name || ' rolls ' || v_label || ' against ' || v_t.name || '''s ' || v_against_name || v_know_txt;$a$,
    $a$|| ' rolls ' || v_label || CASE WHEN coalesce((v_first->'knowledge'->>'value')::numeric, 0) > 0 THEN ' (' || (v_first->'knowledge'->>'name') || ' ' || trim_scale((v_first->'knowledge'->>'value')::numeric) || ')' ELSE '' END || ' against ' || trim_scale(v_diff) || CASE WHEN v_discipline$a$];
  FOR i IN 1..array_length(a, 1) LOOP
    n := (length(v) - length(replace(v, a[i], ''))) / length(a[i]);
    IF n <> 1 THEN RAISE EXCEPTION 'rpg_act: anchor % found % times', i, n; END IF;
    v := replace(v, a[i], b[i]);
  END LOOP;
  DROP FUNCTION public.rpg_act(uuid, uuid[], text, uuid, text, numeric, integer, text);
  EXECUTE v;
  REVOKE ALL ON FUNCTION public.rpg_act(uuid, uuid[], text, uuid, text, numeric, integer, text, uuid) FROM PUBLIC, anon;
  GRANT EXECUTE ON FUNCTION public.rpg_act(uuid, uuid[], text, uuid, text, numeric, integer, text, uuid) TO authenticated, service_role;
END $do$;

DO $do$
DECLARE v text; a text[]; b text[]; i integer; n integer;
BEGIN
  v := pg_get_functiondef('public.rpg_sheet(uuid, numeric)'::regprocedure);
  a := ARRAY[
    $a$-- The numbers come from rpg_sheet_values; this adds what the page shows (names, formulas, what a roll needs).$a$,
    $a$  v_bulk    jsonb;
BEGIN$a$,
    $a$  v_tree := public.rpg_skill_tree(v_c.template_id, v_vals);
$a$,
    $a$    CONTINUE WHEN v_d.trainable AND v_tree ? v_d.key AND NOT (v_tree -> v_d.key ->> 'open')::boolean;
$a$];
  b := ARRAY[
    $a$-- The numbers come from rpg_sheet_values; this adds what the page shows (names, formulas, what a roll needs).
-- A knowledge row (rpg_stat_definitions.knows_id: Knowing Bramblemaw) is a kid's to see once its card is shown to
-- players, is on the character's own chain or is a top card, or once this character has met or studied it (any
-- points banked); the game master sees every open one.$a$,
    $a$  v_bulk    jsonb;
  v_gm      boolean;
  v_chain   uuid[];
BEGIN$a$,
    $a$  v_tree := public.rpg_skill_tree(v_c.template_id, v_vals);
  v_gm := public.family_is_parent() OR coalesce(current_setting('rpg.engine', true), '') = 'on';
  v_chain := public.rpg_template_chain(v_c.template_id);
$a$,
    $a$    CONTINUE WHEN v_d.trainable AND v_tree ? v_d.key AND NOT (v_tree -> v_d.key ->> 'open')::boolean;
    -- a knowledge row a kid has no reason to see yet (the card unshown, unmet, unstudied) stays off the sheet
    CONTINUE WHEN v_d.knows_id IS NOT NULL AND NOT v_gm
      AND NOT EXISTS (SELECT 1 FROM public.rpg_creatures k WHERE k.id = v_d.knows_id AND (k.shown_to_players OR k.parent_id IS NULL OR k.id = ANY (v_chain)))
      AND NOT EXISTS (SELECT 1 FROM public.rpg_character_skills s WHERE s.character_id = p_character_id AND s.stat_key = v_d.key AND (s.skill_points > 0 OR s.earned_levels > 0));
$a$];
  FOR i IN 1..array_length(a, 1) LOOP
    n := (length(v) - length(replace(v, a[i], ''))) / length(a[i]);
    IF n <> 1 THEN RAISE EXCEPTION 'rpg_sheet: anchor % found % times', i, n; END IF;
    v := replace(v, a[i], b[i]);
  END LOOP;
  
  EXECUTE v;
  
END $do$;

DO $do$
DECLARE v text; a text[]; b text[]; i integer; n integer;
BEGIN
  v := pg_get_functiondef('public.rpg_rules_page(integer)'::regprocedure);
  a := ARRAY[
    $a$-- card has been shown to them. Stats every Human has (shared, or on Creature above it) carry no card name.$a$,
    $a$WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND d.grp <> 'basic'$a$];
  b := ARRAY[
    $a$-- card has been shown to them. Stats every Human has (shared, or on Creature above it) carry no card name.
-- A knowledge stat (Knowing Bramblemaw) is on every creature's sheet, so it carries no card name; players see it once
-- that card is shown to them (Knowing Creature, Object and Human always).$a$,
    $a$WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND d.grp <> 'basic'
                AND (d.knows_id IS NULL OR gm.is_gm OR EXISTS (SELECT 1 FROM public.rpg_creatures k WHERE k.id = d.knows_id AND (k.shown_to_players OR k.parent_id IS NULL OR k.id = ANY (hc.chain))))$a$];
  FOR i IN 1..array_length(a, 1) LOOP
    n := (length(v) - length(replace(v, a[i], ''))) / length(a[i]);
    IF n <> 1 THEN RAISE EXCEPTION 'rpg_rules_page: anchor % found % times', i, n; END IF;
    v := replace(v, a[i], b[i]);
  END LOOP;
  
  EXECUTE v;
  
END $do$;

INSERT INTO public.rpg_rules (agency_id, key, title, body, source, sort_order, section)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'knowledge', 'Knowing Things', $b$Every card has a knowledge skill: Knowing Bramblemaw, Knowing Sword. It is built on the knowledge of the card above it plus its own levels, so the card tree is the knowledge tree. Knowing Creature and Knowing Object are the roots. Every creature and human can learn; objects know nothing.
*Knowing Bramblemaw = Knowing Creature + its own levels. Knowing Creature 1 and two levels of its own make Knowing Bramblemaw 3.*

Knowledge counts on both sides of every roll at a being. The roller adds their knowledge of the target's card to the skill. The target adds its knowledge of the roller's card to the stat it defends with (evade, block, a contest), before the × 2.
*Karen's Sword 8 at a Bramblemaw with Evade Enemy 8: difficulty 16, Needed 100 × 16 ÷ (16 + 8) = 67. With Knowing Bramblemaw 3 her Sword rolls as 11: Needed 100 × 16 ÷ 27 = 59. The Bramblemaw's Claw 10 at Karen (Evade Enemy 5): Needed 50; with her Knowing Bramblemaw 3 she defends with 8, × 2 = 16, Needed 100 × 16 ÷ 26 = 62.*

Knowledge grows two ways. Studying is rolling the knowledge skill itself against the game master's difficulty: its points land on it whole, and half flow up to the card above. Meeting is every roll at a being of that card: the knowledge takes a share of the roll's points as one more weight-1 part, like a basic.
*Karen studies Creature at 0 against 8: Needed 100, she fails but earns the die, about 50 points; level 1 costs 1,000, about 20 rolls, and Knowing Bramblemaw opens reading 1. A 27-point swing at a Bramblemaw sends 1.5 to Knowing Bramblemaw and 0.75 of that on to Knowing Creature.*

A knowledge skill opens, trains and turns second nature like any skill. Knowing Creature is a root: bar 3, always open. Knowing Bramblemaw opens when Knowing Creature is 1, and is second nature at 3 once Knowing Creature is. A new being knows nothing unless its card says so. A player's sheet lists a knowledge skill once that card is shown to players, or once the character has met or studied it.$b$, 'peter', 67, 'Getting Better'
WHERE NOT EXISTS (SELECT 1 FROM public.rpg_rules r WHERE r.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND r.key = 'knowledge');

