-- Roleplaying, character model 2.0 (Peter 2026-09-26, the evil step, decisions 1A + 2A): every Spirit trait is a PAIR
-- of two positive numbers, a good side and an evil side (Love / Hatred ...). The net, winner minus loser, feeds every
-- formula and roll; the label on the sheet is the winner's. A new root pair, Connection with God / Fascination with
-- Evil (Peter's words), says which side a being is on and is the source: a fruit cannot grow past the root on its side.
-- Growth on one side pulls the other side down by as much; a loss through an event lowers one side only (apathy is
-- both sides low). rpg_adjust_trait is the one function that moves a basic trait. Cards decide which side rolls: the
-- Human card sets every evil side to 0. Nothing else about the sheet math changes.

ALTER TABLE public.rpg_stat_definitions ADD COLUMN IF NOT EXISTS pair_key text;
ALTER TABLE public.rpg_stat_definitions ADD COLUMN IF NOT EXISTS side text;
ALTER TABLE public.rpg_stat_definitions DROP CONSTRAINT IF EXISTS rpg_stat_definitions_side_check;
ALTER TABLE public.rpg_stat_definitions ADD CONSTRAINT rpg_stat_definitions_side_check CHECK (side IS NULL OR side IN ('good', 'evil'));
COMMENT ON COLUMN public.rpg_stat_definitions.pair_key IS 'For a paired Spirit trait: the key of its opposite (Love ↔ Hatred). The pair shows as one line, the winner''s name, and its net (winner minus loser) feeds every formula.';
COMMENT ON COLUMN public.rpg_stat_definitions.side IS 'good or evil for a paired Spirit trait; null for everything else.';

-- 1. The root pair, first in Spirit, and the evil side of each fruit. Mind moves to 95-98 so the Rules tab keeps
--    Spirit, Mind, Body in order.
UPDATE public.rpg_stat_definitions SET sort_order = CASE key WHEN 'IN' THEN 95 WHEN 'FO' THEN 96 WHEN 'ME' THEN 97 WHEN 'PR' THEN 98 END
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key IN ('IN','FO','ME','PR');
INSERT INTO public.rpg_stat_definitions (key, name, abbr, grp, kind, trainable, default_value, sort_order, side, pair_key)
VALUES
  ('CG', 'Connection with God',   'CG', 'strength', 'rolled', false, 0, 5,  'good', 'FE'),
  ('FE', 'Fascination with Evil', 'FE', 'strength', 'rolled', false, 0, 6,  'evil', 'CG'),
  ('HT', 'Hatred',        'HT', 'strength', 'rolled', false, 0, 11, 'evil', 'LO'),
  ('MI', 'Misery',        'MI', 'strength', 'rolled', false, 0, 21, 'evil', 'JO'),
  ('SR', 'Strife',        'SR', 'strength', 'rolled', false, 0, 31, 'evil', 'PE'),
  ('RA', 'Rage',          'RA', 'strength', 'rolled', false, 0, 41, 'evil', 'PA'),
  ('CR', 'Cruelty',       'CR', 'strength', 'rolled', false, 0, 51, 'evil', 'KI'),
  ('WK', 'Wickedness',    'WK', 'strength', 'rolled', false, 0, 61, 'evil', 'GO'),
  ('TR', 'Treachery',     'TR', 'strength', 'rolled', false, 0, 71, 'evil', 'FA'),
  ('BU', 'Brutality',     'BU', 'strength', 'rolled', false, 0, 81, 'evil', 'GE'),
  ('RK', 'Recklessness',  'RK', 'strength', 'rolled', false, 0, 91, 'evil', 'SC')
ON CONFLICT (agency_id, key) DO NOTHING;
UPDATE public.rpg_stat_definitions d SET side = 'good', pair_key = e.key
  FROM public.rpg_stat_definitions e
 WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND e.agency_id = d.agency_id AND e.side = 'evil' AND e.pair_key = d.key;

-- 2. The Human card rolls the good sides; every evil side starts at 0.
UPDATE public.rpg_creatures
   SET blueprint = blueprint || '{"FE": 0, "HT": 0, "MI": 0, "SR": 0, "RA": 0, "CR": 0, "WK": 0, "TR": 0, "BU": 0, "RK": 0}'::jsonb
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'human';

-- 3. Existing characters: evil sides 0, Connection with God rolled once (through the one generator; existing numbers win).
SELECT set_config('request.jwt.claims', '{"sub":"dc9a6291-6d79-410b-9870-ff5d0c81a7f0","role":"authenticated"}', true);
UPDATE public.rpg_characters c
   SET inputs = public.rpg_roll_inputs(c.template_key) || c.inputs
 WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND NOT (c.inputs ?& ARRAY['CG','FE','HT','MI','SR','RA','CR','WK','TR','BU','RK']);

-- 4. The sheet: pairs net out, one line per pair with the winner's name, and the being's side from the root.
DO $m$
DECLARE
  v_def text;
  v_old text;
  v_new text;
  v_i   integer;
BEGIN
  v_def := pg_get_functiondef('public.rpg_sheet(uuid,numeric)'::regprocedure);
  FOR v_i IN 1..5 LOOP
    v_old := CASE v_i
      WHEN 1 THEN E'  v_pv      numeric;\nBEGIN'
      WHEN 2 THEN E'    v_vals := v_vals || jsonb_build_object(v_d.key, v_v);\n  END LOOP;\n\n  -- derived stats'
      WHEN 3 THEN E'  FOREACH v_d IN ARRAY v_defs LOOP\n    v_v := coalesce((v_vals->>v_d.key)::numeric, 0);\n    v_nc := public.rpg_needed(v_v, v_diff);\n    v_stats := v_stats || jsonb_build_object(\n      ''key'', v_d.key, ''name'', v_d.name,'
      WHEN 4 THEN E'      ''formula_text'', public.rpg_formula_text(v_d.formula, v_names));\n  END LOOP;'
      WHEN 5 THEN E'    ''id'', v_c.id, ''name'', v_c.name, ''template_key'', v_c.template_key,' END;
    v_new := CASE v_i
      WHEN 1 THEN E'  v_pv      numeric;\n  v_raw     jsonb;\n  v_good    numeric;\n  v_evil    numeric;\n  v_side    text := ''good'';\nBEGIN'
      WHEN 2 THEN E'    v_vals := v_vals || jsonb_build_object(v_d.key, v_v);\n  END LOOP;\n\n'
               || E'  -- paired Spirit traits: the net (winner minus loser) feeds every formula; the label is the winner''s.\n'
               || E'  -- The root pair (Connection with God / Fascination with Evil) says which side the being is on.\n'
               || E'  v_raw := v_vals;\n'
               || E'  FOREACH v_d IN ARRAY v_defs LOOP\n'
               || E'    CONTINUE WHEN v_d.side IS DISTINCT FROM ''good'' OR v_d.pair_key IS NULL;\n'
               || E'    v_good := coalesce((v_raw->>v_d.key)::numeric, 0); v_evil := coalesce((v_raw->>v_d.pair_key)::numeric, 0);\n'
               || E'    v_vals := v_vals || jsonb_build_object(v_d.key, abs(v_good - v_evil), v_d.pair_key, 0);\n'
               || E'    IF v_d.key = ''CG'' AND v_evil > v_good THEN v_side := ''evil''; END IF;\n'
               || E'  END LOOP;\n\n  -- derived stats'
      WHEN 3 THEN E'  FOREACH v_d IN ARRAY v_defs LOOP\n    CONTINUE WHEN v_d.side = ''evil'';\n    v_v := coalesce((v_vals->>v_d.key)::numeric, 0);\n    v_nc := public.rpg_needed(v_v, v_diff);\n'
               || E'    v_good := coalesce((v_raw->>v_d.key)::numeric, 0); v_evil := CASE WHEN v_d.pair_key IS NULL THEN 0 ELSE coalesce((v_raw->>v_d.pair_key)::numeric, 0) END;\n'
               || E'    v_stats := v_stats || jsonb_build_object(\n'
               || E'      ''key'', v_d.key, ''name'', CASE WHEN v_d.pair_key IS NOT NULL AND v_evil > v_good THEN v_names->>v_d.pair_key ELSE v_d.name END,\n'
               || E'      ''pair_key'', v_d.pair_key, ''side'', CASE WHEN v_d.pair_key IS NULL THEN NULL WHEN v_evil > v_good THEN ''evil'' ELSE ''good'' END,\n'
               || E'      ''good_name'', CASE WHEN v_d.pair_key IS NULL THEN NULL ELSE v_d.name END, ''evil_name'', CASE WHEN v_d.pair_key IS NULL THEN NULL ELSE v_names->>v_d.pair_key END,\n'
               || E'      ''good'', CASE WHEN v_d.pair_key IS NULL THEN NULL ELSE v_good END, ''evil'', CASE WHEN v_d.pair_key IS NULL THEN NULL ELSE v_evil END,'
      WHEN 4 THEN E'      ''formula_text'', public.rpg_formula_text(v_d.formula, v_names));\n  END LOOP;'
      WHEN 5 THEN E'    ''id'', v_c.id, ''name'', v_c.name, ''template_key'', v_c.template_key, ''side'', v_side,' END;
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
      RAISE EXCEPTION 'rpg_sheet: anchor % is not there exactly once', v_i;
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END LOOP;
  EXECUTE v_def;
END $m$;

-- 5. The one function that moves a basic trait: growth pulls the pair''s other side down as much, and a fruit cannot
--    grow past the root on its side; a loss lowers one side only. Parents only (an event at the table).
CREATE OR REPLACE FUNCTION public.rpg_adjust_trait(p_character_id uuid, p_key text, p_delta integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Moves one rolled or fixed trait by p_delta (an event: a kindness, a lie, a season of prayer). For a paired Spirit
-- trait: growth (+) is capped by the root on that side (Connection with God for a good side, Fascination with Evil for
-- an evil side; the root itself has no cap) and pulls the opposite side down by as much as actually grew; a loss (−)
-- lowers this side only, never below 0. Love 7 / Hatred 2, Hatred +3 → Hatred 5, Love 4. Love 4 with Connection 3:
-- Love +1 is refused until Connection grows. Body and Mind traits move plainly. Returns the sheet.
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
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'parents only'; END IF;
  IF coalesce(p_delta, 0) = 0 THEN RETURN public.rpg_sheet(p_character_id); END IF;
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
      SELECT name INTO v_root FROM public.rpg_stat_definitions WHERE agency_id = v_c.agency_id AND key = v_root_key;
      IF v_now >= v_cap THEN
        RAISE EXCEPTION '% cannot grow past % (%): grow that first', v_d.name, v_root, v_cap;
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
  RETURN public.rpg_sheet(p_character_id);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.rpg_adjust_trait(uuid, text, integer) TO authenticated;

-- 6. The rule card.
UPDATE public.rpg_rules
   SET body = body || E'\n\n' || 'Every Spirit trait is a pair: a good side and an evil side, Love and Hatred, Patience and Rage, and so on, each its own number. The sheet shows the winning side by name, and what counts in every formula is the winner minus the loser: Love 7 against Hatred 2 plays as Love 5. The root pair is Connection with God and Fascination with Evil; it says which side a being is on, and it is the source: a fruit cannot grow past the root on its side, so Love cannot pass Connection with God 4 until that grows. When a side grows, the other side falls by as much; when a side is lowered by an event, the other side stays where it was, so a being that has lost its love has not gained hatred. A player character rolls the good sides; the evil sides start at 0.'
 WHERE key = 'strength_roll' AND body NOT LIKE '%Every Spirit trait is a pair%';

DO $g$
DECLARE v_n integer; v_missing integer;
BEGIN
  SELECT count(*) INTO v_n FROM public.rpg_stat_definitions WHERE side = 'good' AND pair_key IS NOT NULL;
  IF v_n <> 10 THEN RAISE EXCEPTION 'expected ten good sides paired, found %', v_n; END IF;
  SELECT count(*) INTO v_n FROM public.rpg_stat_definitions d
   WHERE d.pair_key IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.rpg_stat_definitions e WHERE e.key = d.pair_key AND e.pair_key = d.key AND e.side <> d.side);
  IF v_n <> 0 THEN RAISE EXCEPTION '% pairs do not point at each other', v_n; END IF;
  SELECT count(*) INTO v_missing FROM public.rpg_characters WHERE NOT (inputs ?& ARRAY['CG','FE','HT','MI','SR','RA','CR','WK','TR','BU','RK']);
  IF v_missing > 0 THEN RAISE EXCEPTION '% character(s) lack the pairs', v_missing; END IF;
  IF (SELECT blueprint ->> 'HT' FROM public.rpg_creatures WHERE key = 'human') IS DISTINCT FROM '0' THEN
    RAISE EXCEPTION 'the Human card does not set the evil sides to 0';
  END IF;
  IF pg_get_functiondef('public.rpg_sheet(uuid,numeric)'::regprocedure) NOT LIKE '%''evil_name''%' THEN
    RAISE EXCEPTION 'rpg_sheet did not take the pairs';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.rpg_adjust_trait(uuid, text, integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'rpg_adjust_trait is not callable';
  END IF;
END $g$;

NOTIFY pgrst, 'reload schema';
