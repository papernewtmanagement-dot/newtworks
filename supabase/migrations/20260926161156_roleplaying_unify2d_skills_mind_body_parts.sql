-- Roleplaying, character model 2.0 (Peter 2026-09-26, decision 1A of the skills step): every skill keeps the Spirit
-- parts Peter's manual gave it and gains the Mind and Body parts the research puts there (Cattell-Horn-Carroll for
-- knowledge and memory; Posner and Simons for attention and noticing; Sheppard & Young for agility's decision part;
-- Marcora for endurance as body plus will; Caspersen / Fleishman for strength and agility in physical work). Every
-- divisor is the sum of the weights, the manual's own convention, so a human still averages about 5. Attention to
-- Detail and Train Animals, fixed at 0 until now, get parents. The armor of God stays Spirit only. Earned levels and
-- skill points (rpg_character_skills) are untouched; only the base moves.
WITH f(key, formula) AS (VALUES
  ('BLK',  '{"div": 4,  "parts": [["ST",1],["AG",1],["SC",1],["PR",1]]}'),
  ('CO',   '{"div": 6,  "parts": [["LO",1],["JO",1],["GO",1],["FA",1],["SC",1],["FO",1]]}'),
  ('EN',   '{"div": 10, "parts": [["JO",1],["PE",1],["PA",2],["FA",1],["SC",2],["TO",2],["ST",1]]}'),
  ('HO',   '{"div": 7,  "parts": [["JO",3],["PE",1],["PA",1],["FA",1],["IN",1]]}'),
  ('KN',   '{"div": 8,  "parts": [["JO",1],["PA",1],["GO",1],["FA",1],["IN",2],["ME",2]]}'),
  ('LIS',  '{"div": 7,  "parts": [["PE",2],["PA",1],["SC",1],["PR",2],["FO",1]]}'),
  ('QM',   '{"div": 7,  "parts": [["PE",1],["PA",1],["SC",1],["EN",1],["AG",2],["FO",1]]}'),
  ('VIS',  '{"div": 6,  "parts": [["PA",1],["FA",1],["HO",1],["PR",3]]}'),
  ('WIS',  '{"div": 10, "parts": [["LO",3],["JO",1],["PE",1],["KI",1],["GO",1],["GE",1],["IN",2]]}'),
  ('BWS',  '{"div": 7,  "parts": [["SC",2],["PA",1],["EN",2],["PR",1],["FO",1]]}'),
  ('CL',   '{"div": 11, "parts": [["JO",1],["PE",1],["PA",1],["SC",2],["EN",1],["CO",1],["ST",2],["AG",1],["TO",1]]}'),
  ('CA',   '{"div": 4,  "parts": [["JO",1],["KI",1],["GE",1],["PR",1]]}'),
  ('PF',   '{"div": 8,  "parts": [["FA",2],["SC",1],["KN",1],["WIS",2],["CO",1],["IN",1]]}'),
  ('SE',   '{"div": 5,  "parts": [["GO",2],["KN",1],["CO",1],["PR",1]]}'),
  ('TL',   '{"div": 7,  "parts": [["LO",1],["KI",2],["GO",1],["GE",2],["IN",1]]}'),
  ('TE',   '{"div": 6,  "parts": [["JO",1],["PA",1],["SC",1],["PR",2],["ME",1]]}'),
  ('WM',   '{"div": 8,  "parts": [["JO",1],["SC",1],["EN",2],["CO",1],["ST",1],["AG",1],["TO",1]]}'),
  ('EE',   '{"div": 5,  "parts": [["PE",1],["PA",1],["SC",1],["AG",1],["PR",1]]}'),
  ('RFI',  '{"div": 7,  "parts": [["HO",3],["CO",1],["EN",1],["TO",2]]}'),
  ('RT',   '{"div": 9,  "parts": [["JO",1],["FA",2],["SC",1],["HO",1],["CO",1],["EN",1],["TO",1],["FO",1]]}'),
  ('TA',   '{"div": 4,  "parts": [["PA",1],["SC",1],["FO",1],["CA",1]]}'),
  ('ATD',  '{"div": 3,  "parts": [["FO",1],["PR",1],["PA",1]]}'),
  ('SB',   '{"div": 5,  "parts": [["PE",1],["EN",1],["CO",2],["FO",1]]}'),
  ('battle_axe',    '{"div": 6, "parts": [["HO",1],["CO",1],["EN",1],["HE",1],["ST",2]]}'),
  ('crossbow',      '{"div": 5, "parts": [["HO",1],["VIS",1],["ST",1],["PA",1],["FO",1]]}'),
  ('dagger',        '{"div": 5, "parts": [["CO",1],["SC",1],["SB",1],["AG",2]]}'),
  ('flail',         '{"div": 5, "parts": [["HO",1],["CO",1],["EN",1],["ST",1],["AG",1]]}'),
  ('hand_axe',      '{"div": 5, "parts": [["HO",1],["CO",1],["SB",1],["ST",1],["AG",1]]}'),
  ('hand_to_hand',  '{"div": 7, "parts": [["SC",1],["CO",1],["EN",1],["SB",1],["ST",1],["AG",1],["TO",1]]}'),
  ('lance',         '{"div": 6, "parts": [["CO",1],["EN",1],["SE",1],["SB",1],["ST",1],["AG",1]]}'),
  ('longbow',       '{"div": 5, "parts": [["HO",1],["VIS",1],["ST",1],["QM",1],["FO",1]]}'),
  ('military_fork', '{"div": 6, "parts": [["CO",1],["EN",1],["SE",1],["SC",1],["ST",1],["AG",1]]}'),
  ('quarterstaff',  '{"div": 5, "parts": [["HO",1],["CO",1],["SB",1],["AG",1],["ST",1]]}'),
  ('sling',         '{"div": 5, "parts": [["HO",1],["CO",1],["SC",1],["AG",1],["PR",1]]}'),
  ('spear',         '{"div": 6, "parts": [["CO",1],["EN",1],["SE",1],["SB",1],["ST",1],["AG",1]]}'),
  ('sword',         '{"div": 5, "parts": [["CO",1],["EN",1],["SB",1],["AG",1],["ST",1]]}'),
  ('war_hammer',    '{"div": 6, "parts": [["HO",1],["CO",1],["EN",1],["HE",1],["ST",2]]}')
)
UPDATE public.rpg_stat_definitions d
   SET formula = f.formula::jsonb, kind = 'derived'
  FROM f WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND d.key = f.key;

-- Block's sentence on the rule card follows its formula.
UPDATE public.rpg_rules
   SET body = replace(body,
     'Block = Strength, Agility and Self-Control averaged, plus what is held',
     'Block = Strength, Agility, Self-Control and Perception averaged, plus what is held')
 WHERE key = 'attack_gates' AND body LIKE '%Block = Strength, Agility and Self-Control averaged%';

DO $g$
DECLARE v_bad text; v_n integer;
BEGIN
  -- every part names a stat that exists, and every divisor is the sum of its weights
  SELECT string_agg(DISTINCT d.key, ', ') INTO v_bad
    FROM public.rpg_stat_definitions d CROSS JOIN LATERAL jsonb_array_elements(d.formula->'parts') p
   WHERE d.kind = 'derived' AND NOT EXISTS (SELECT 1 FROM public.rpg_stat_definitions x WHERE x.key = p->>0);
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'formulas name stats that do not exist: %', v_bad; END IF;
  SELECT string_agg(d.key, ', ') INTO v_bad
    FROM public.rpg_stat_definitions d
   WHERE d.kind = 'derived' AND d.key NOT IN ('PV', 'IG', 'PEN', 'PER', 'SEN', 'SER', 'BT', 'BR', 'HS', 'healing_physical')
     AND (SELECT sum((p->>1)::numeric) FROM jsonb_array_elements(d.formula->'parts') p) <> coalesce((d.formula->>'div')::numeric, 1);
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'divisor is not the sum of the weights: %', v_bad; END IF;
  SELECT count(*) INTO v_n FROM public.rpg_stat_definitions WHERE kind = 'fixed';
  IF v_n <> 1 THEN RAISE EXCEPTION 'only Sword of the Spirit should be fixed now, found %', v_n; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rpg_rules WHERE key = 'attack_gates' AND body LIKE '%Self-Control and Perception averaged%') THEN
    RAISE EXCEPTION 'the attack gates card did not take the Block change';
  END IF;
END $g$;

NOTIFY pgrst, 'reload schema';
