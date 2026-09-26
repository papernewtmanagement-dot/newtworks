-- Roleplaying, character model 2.0 (Peter 2026-09-26, decisions 1A + 2A of the derived-trait step):
-- Physical Vitality is built from the Body: 3 × Toughness + 2 × Strength (a human lands 5 to 50; Bramblemaw's card
-- will set Toughness 40 and Strength 15 for 150). Integrity is new: Toughness ÷ 5, rounded down, the damage a blow
-- must clear after armor or it does nothing (a human 0 to 2, Bramblemaw 8, a stone wall 20). The derived traits
-- (the pools and thresholds nobody trains: Physical Vitality, Integrity, the two energy pools and their regains) get
-- a group of their own so the sheet shows them apart from the rolled traits.

ALTER TABLE public.rpg_stat_definitions DROP CONSTRAINT IF EXISTS rpg_stat_definitions_grp_check;
ALTER TABLE public.rpg_stat_definitions ADD CONSTRAINT rpg_stat_definitions_grp_check
  CHECK (grp = ANY (ARRAY['strength'::text, 'mind'::text, 'physical'::text, 'derived'::text, 'spiritual'::text, 'ability'::text, 'fighting'::text]));

-- 1. Physical Vitality from the Body.
UPDATE public.rpg_stat_definitions
   SET formula = '{"div": 1, "parts": [["TO", 3], ["ST", 2]]}'::jsonb, grp = 'derived', sort_order = 150
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'PV';

-- 2. Integrity, the damage threshold.
INSERT INTO public.rpg_stat_definitions (key, name, abbr, grp, kind, trainable, formula, default_value, sort_order)
VALUES ('IG', 'Integrity', 'IG', 'derived', 'derived', false, '{"div": 5, "parts": [["TO", 1]]}'::jsonb, 0, 151)
ON CONFLICT (agency_id, key) DO NOTHING;

-- 3. The energy pools and regains join the derived group (formulas unchanged).
UPDATE public.rpg_stat_definitions SET grp = 'derived', sort_order = CASE key WHEN 'PEN' THEN 152 WHEN 'PER' THEN 153 WHEN 'SEN' THEN 154 WHEN 'SER' THEN 155 END
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key IN ('PEN', 'PER', 'SEN', 'SER');

-- 4. The hit gate: what is left after armor must clear the target's Integrity or it does nothing ("Bounced off").
DO $m$
DECLARE
  v_def text;
  v_old text;
  v_new text;
  v_i   integer;
BEGIN
  v_def := pg_get_functiondef('public.rpg_act(uuid,uuid[],text,uuid,text,numeric,integer,text)'::regprocedure);
  FOR v_i IN 1..3 LOOP
    v_old := CASE v_i
      WHEN 1 THEN 'v_blk numeric; v_blocker uuid; v_blocker_name text; v_broll jsonb; v_blocked boolean; v_absorb integer; v_wear jsonb; v_weapon uuid;'
      WHEN 2 THEN E'      IF v_net > 0 THEN v_vit := public.rpg_session_adjust_vitality(v_tid, v_net);\n      ELSE v_vit := public.rpg_participant_vitality(v_tid); END IF;\n      v_out := CASE WHEN v_blocked THEN jsonb_build_object(''key'', ''blocked'', ''label'', ''Blocked'')'
      WHEN 3 THEN 'IF v_kind = ''action'' AND v_fx IS NOT NULL AND v_first->>''result'' <> '''' AND NOT v_blocked AND (v_vit->>''left'')::integer > 0 THEN' END;
    v_new := CASE v_i
      WHEN 1 THEN v_old || ' v_integrity integer; v_bounced boolean;'
      WHEN 2 THEN E'      -- Integrity: what is left after armor must clear the target''s Integrity (Toughness ÷ 5) or it does nothing.\n'
               || E'      v_bounced := false;\n'
               || E'      IF v_net > 0 AND NOT v_blocked THEN\n'
               || E'        v_integrity := coalesce(public.rpg_participant_value(v_tid, ''IG''), 0)::integer;\n'
               || E'        IF v_net <= v_integrity THEN\n'
               || E'          v_bounced := true;\n'
               || E'          v_tail := v_tail || '' '' || v_net || '' does not get through '' || v_t.name || ''''''s Integrity of '' || v_integrity || ''.'';\n'
               || E'          v_net := 0;\n'
               || E'        END IF;\n'
               || E'      END IF;\n'
               || E'      IF v_net > 0 THEN v_vit := public.rpg_session_adjust_vitality(v_tid, v_net);\n      ELSE v_vit := public.rpg_participant_vitality(v_tid); END IF;\n'
               || E'      v_out := CASE WHEN v_blocked THEN jsonb_build_object(''key'', ''blocked'', ''label'', ''Blocked'')\n'
               || E'                    WHEN v_bounced THEN jsonb_build_object(''key'', ''bounced'', ''label'', ''Bounced off'')'
      WHEN 3 THEN 'IF v_kind = ''action'' AND v_fx IS NOT NULL AND v_first->>''result'' <> '''' AND NOT v_blocked AND NOT v_bounced AND (v_vit->>''left'')::integer > 0 THEN' END;
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
      RAISE EXCEPTION 'rpg_act: anchor % is not there exactly once', v_i;
    END IF;
    v_def := replace(v_def, v_old, v_new);
  END LOOP;
  EXECUTE v_def;
END $m$;

-- 5. Rule cards. Gate 3 gains the Integrity sentence; the object's life is called what it is on every sheet; the log
--    learns the new word.
UPDATE public.rpg_rules
   SET body = replace(replace(body,
     'What is left reaches the target.',
     'What is left must clear the target''s Integrity (Toughness ÷ 5, rounded down) or it does nothing: a person''s Integrity is 0 to 2, Bramblemaw''s 8, a stone wall''s 20, so a blow of 8 bounces off Bramblemaw and a 9 does 9. Only what clears it reaches the target.'),
     'Every object has integrity, its life; at 0 it stops working',
     'Every object has a life of its own, like a character''s vitality; at 0 it stops working')
 WHERE key = 'attack_gates' AND body LIKE '%What is left reaches the target.%';

UPDATE public.rpg_rules
   SET body = replace(body,
     'A check says Success or Fail.',
     'Bounced off: the blow landed but did not clear the target''s Integrity. A check says Success or Fail.')
 WHERE key = 'log_outcomes' AND body LIKE '%A check says Success or Fail.%' AND body NOT LIKE '%Bounced off%';

UPDATE public.rpg_rules
   SET body = replace(body,
     'Everything else on the sheet is calculated from those numbers.',
     'Everything else on the sheet is calculated from those numbers. The derived traits come first: Physical Vitality is 3 × Toughness + 2 × Strength (Toughness 7 and Strength 10 make 41); Integrity is Toughness ÷ 5, rounded down; the energy pools follow the skills that feed them.')
 WHERE key = 'strength_roll' AND body LIKE '%Everything else on the sheet is calculated from those numbers.' AND body NOT LIKE '%The derived traits come first%';

DO $g$
BEGIN
  IF (SELECT formula::text FROM public.rpg_stat_definitions WHERE key = 'PV') <> '{"div": 1, "parts": [["TO", 3], ["ST", 2]]}' THEN
    RAISE EXCEPTION 'Physical Vitality did not take the Body formula';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rpg_stat_definitions WHERE key = 'IG' AND grp = 'derived') THEN
    RAISE EXCEPTION 'Integrity is missing';
  END IF;
  IF (SELECT count(*) FROM public.rpg_stat_definitions WHERE grp = 'derived') <> 6 THEN
    RAISE EXCEPTION 'the derived group should hold six traits';
  END IF;
  IF pg_get_functiondef('public.rpg_act(uuid,uuid[],text,uuid,text,numeric,integer,text)'::regprocedure) NOT LIKE '%''bounced''%' THEN
    RAISE EXCEPTION 'rpg_act did not take the Integrity gate';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rpg_rules WHERE key = 'attack_gates' AND body LIKE '%must clear the target''s Integrity%') THEN
    RAISE EXCEPTION 'the attack gates rule did not take Integrity';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rpg_rules WHERE key = 'log_outcomes' AND body LIKE '%Bounced off%') THEN
    RAISE EXCEPTION 'the log rule did not take Bounced off';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.rpg_act(uuid,uuid[],text,uuid,text,numeric,integer,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'rpg_act lost its grant';
  END IF;
END $g$;

NOTIFY pgrst, 'reload schema';
