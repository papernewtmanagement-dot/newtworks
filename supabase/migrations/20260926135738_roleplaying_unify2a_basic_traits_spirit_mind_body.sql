-- Roleplaying, character model 2.0 (Peter 2026-09-26, decisions 1A + 2A): the basic (rolled) traits sit in three groups,
-- Spirit, Mind, Body, in that order, and together are called traits. Spirit = the nine fruits (grp 'strength', as
-- before). Mind = Intelligence, Focus, Memory, Perception (new grp 'mind'). Body = Strength, Agility (grp 'physical',
-- as before) plus Toughness (new). Every rolled trait follows the one rolling rule (d100 ÷ 10 rounded up, 1 to 10;
-- a card may set a number or change the divider, never under 1). Existing characters roll the five new traits once,
-- back-filled here; nothing derives from them yet (the derived traits are the next step).

ALTER TABLE public.rpg_stat_definitions DROP CONSTRAINT IF EXISTS rpg_stat_definitions_grp_check;
ALTER TABLE public.rpg_stat_definitions ADD CONSTRAINT rpg_stat_definitions_grp_check
  CHECK (grp = ANY (ARRAY['strength'::text, 'mind'::text, 'physical'::text, 'spiritual'::text, 'ability'::text, 'fighting'::text]));

INSERT INTO public.rpg_stat_definitions (key, name, abbr, grp, kind, trainable, default_value, sort_order)
VALUES
  ('IN', 'Intelligence', 'IN', 'mind',     'rolled', false, 0, 91),
  ('FO', 'Focus',        'FO', 'mind',     'rolled', false, 0, 92),
  ('ME', 'Memory',       'ME', 'mind',     'rolled', false, 0, 93),
  ('PR', 'Perception',   'PR', 'mind',     'rolled', false, 0, 94),
  ('TO', 'Toughness',    'TO', 'physical', 'rolled', false, 0, 130)
ON CONFLICT (agency_id, key) DO NOTHING;

-- Back-fill: every existing character rolls the new traits once, through the one generator (rpg_roll_inputs, which
-- needs a family login, so the game master's claims are set for this transaction only). Existing numbers win.
SELECT set_config('request.jwt.claims', '{"sub":"dc9a6291-6d79-410b-9870-ff5d0c81a7f0","role":"authenticated"}', true);
UPDATE public.rpg_characters c
   SET inputs = public.rpg_roll_inputs(c.template_key) || c.inputs
 WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND NOT (c.inputs ?& ARRAY['IN','FO','ME','PR','TO']);

-- The rule card's first sentence lists what rolls; the new traits join the list. The rest of the card is unchanged.
UPDATE public.rpg_rules
   SET body = replace(body,
     'Each of the nine strengths, plus Strength and Agility, rolls a d100 divided by 10 and rounded up, so every result is 1 to 10.',
     'Each of the nine strengths, plus Intelligence, Focus, Memory, Perception, Strength, Agility and Toughness, rolls a d100 divided by 10 and rounded up, so every result is 1 to 10.')
 WHERE key = 'strength_roll' AND body LIKE 'Each of the nine strengths, plus Strength and Agility, rolls a d100%';

DO $g$
DECLARE v_missing integer; v_n integer;
BEGIN
  SELECT count(*) INTO v_n FROM public.rpg_stat_definitions WHERE key IN ('IN','FO','ME','PR','TO') AND kind = 'rolled';
  IF v_n <> 5 THEN RAISE EXCEPTION 'expected five new rolled traits, found %', v_n; END IF;
  SELECT count(*) INTO v_missing FROM public.rpg_characters WHERE NOT (inputs ?& ARRAY['IN','FO','ME','PR','TO']);
  IF v_missing > 0 THEN RAISE EXCEPTION '% character(s) still lack the new traits', v_missing; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rpg_rules WHERE key = 'strength_roll' AND body LIKE '%Perception, Strength, Agility and Toughness, rolls%') THEN
    RAISE EXCEPTION 'the rule card did not take the new traits';
  END IF;
END $g$;

NOTIFY pgrst, 'reload schema';
