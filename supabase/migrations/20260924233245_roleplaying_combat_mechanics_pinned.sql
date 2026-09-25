-- Roleplaying: combat mechanics pinned 2026-09-24 (spec "Roleplaying combat mechanics", <ruled> block).
-- One formula everywhere. Needed = the lowest d100 result that counts.
--   Against a fixed challenge (a wall, a lock, a jump, a sleeping or bound foe):
--     Needed = 100 × D ÷ (D + S)           skill 5 vs difficulty 5 → 50 (lands about half the time)
--   Against an opponent who can act (defending, resisting, hiding), the difficulty is their skill and counts double:
--     Needed = 100 × 2D ÷ (2D + S)         skill 5 vs skill 5 → 66.67 (lands about one time in three)
--   Peter 2026-09-24: "you against an opponent is fighting their skill and their intent to use it, so it doubles;
--   a wall isn't going to try to move." Equal skill landing one in three matches landed rates in combat sports.
--   The fixed-task convention (equal = coin flip) is the item-response / Rasch definition of a task's difficulty:
--   the ability level that succeeds half the time.
-- Skill points every roll, landed or not: points = die × Needed ÷ 100 (bounded by the die itself; a Needed of 0 teaches nothing).
-- Damage (not computed by any function yet; step 5): die − Needed, rounded down, at least 1; a critical's extra roll adds its result.
-- Nothing is deleted. The two-argument rpg_needed signature is replaced by a three-argument one whose third argument
-- defaults to false, so every existing two-argument call (rpg_sheet, rpg_roll, the Rules tab calculator) resolves unchanged.

-- 1. Who calls rpg_needed today (recorded in the ledger, checked again at the end): rpg_roll, rpg_sheet.
DO $$
DECLARE v_callers text;
BEGIN
  SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO v_callers
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname <> 'rpg_needed'
    AND pg_get_functiondef(p.oid) LIKE '%public.rpg_needed(%';
  RAISE NOTICE 'rpg_needed callers before: %', coalesce(v_callers, '(none)');
END $$;

-- 2. rpg_needed: the two-case formula with an opposed switch.
DROP FUNCTION IF EXISTS public.rpg_needed(numeric, numeric);

CREATE OR REPLACE FUNCTION public.rpg_needed(p_skill numeric, p_difficulty numeric, p_opposed boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Needed = the lowest d100 result that counts. One formula everywhere:
--   fixed challenge (p_opposed false): 100 × D ÷ (D + S)        5 vs 5 → 50
--   opponent who can act (p_opposed true): 100 × 2D ÷ (2D + S)   5 vs 5 → 66.67, 10 vs 5 → 50, 5 vs 10 → 80
-- Difficulty 0 is no challenge → 0 (any roll counts, teaches nothing). Skill 0 → 100 (only a 100 counts).
-- Critical = 100 − (100 − Needed) × crit_chance (unchanged).
SELECT public.require_login('family');
  WITH n AS (
    SELECT CASE WHEN coalesce(p_difficulty, 0) <= 0 THEN 0::numeric
                ELSE 100 * (CASE WHEN p_opposed THEN 2 ELSE 1 END) * p_difficulty
                     / ((CASE WHEN p_opposed THEN 2 ELSE 1 END) * p_difficulty + greatest(coalesce(p_skill, 0), 0))
           END AS needed
  )
  SELECT jsonb_build_object(
    'needed',   round(needed, 2),
    'critical', round(100 - ((100 - needed) * public.rpg_setting('crit_chance')), 2),
    'opposed',  p_opposed)
  FROM n;
$function$;

COMMENT ON FUNCTION public.rpg_needed(numeric, numeric, boolean) IS
'Needed = lowest d100 result that counts. Fixed challenge: 100·D/(D+S). Opponent who can act (p_opposed): 100·2D/(2D+S). Peter 2026-09-24. Sheet, Rules tab calculator and rpg_roll all call this; nothing re-implements it.';

-- 3. rpg_roll: the skill-points line becomes die × Needed ÷ 100. Same signature, same everything else.
CREATE OR REPLACE FUNCTION public.rpg_roll(p_character_id uuid, p_stat_key text, p_difficulty numeric DEFAULT NULL::numeric, p_label text DEFAULT NULL::text, p_parent_roll_id uuid DEFAULT NULL::uuid, p_session_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sheet   jsonb;
  v_stat    jsonb;
  v_skill   numeric;
  v_diff    numeric;
  v_nc      jsonb;
  v_roll    integer;
  v_result  text;
  v_points  numeric := 0;
  v_before  integer;
  v_after   integer;
  v_cost    numeric;
  v_sp      numeric;
  v_earned  integer;
  v_id      uuid;
  v_agency  uuid;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  v_diff := coalesce(p_difficulty, public.rpg_setting('default_difficulty'));
  IF v_diff < 0 THEN RAISE EXCEPTION 'difficulty cannot be negative'; END IF;
  v_sheet := public.rpg_sheet(p_character_id, v_diff);
  SELECT s INTO v_stat FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = p_stat_key;
  IF v_stat IS NULL THEN RAISE EXCEPTION 'unknown stat %', p_stat_key; END IF;
  v_skill := (v_stat->>'value')::numeric;
  v_nc := public.rpg_needed(v_skill, v_diff);
  v_roll := floor(random() * 100)::integer + 1;
  v_result := CASE WHEN v_roll >= (v_nc->>'critical')::numeric THEN 'C'
                   WHEN v_roll >= (v_nc->>'needed')::numeric THEN 'Y' ELSE '' END;
  v_before := v_skill::integer; v_after := v_before;

  IF (v_stat->>'trainable')::boolean THEN
    -- Skill points every roll, landed or not: die × Needed ÷ 100 (Peter 2026-09-24; Needed from rpg_needed, never recomputed here).
    v_points := v_roll * (v_nc->>'needed')::numeric / 100;
    INSERT INTO public.rpg_character_skills (character_id, stat_key) VALUES (p_character_id, p_stat_key)
      ON CONFLICT (character_id, stat_key) DO NOTHING;
    SELECT skill_points, earned_levels INTO v_sp, v_earned
      FROM public.rpg_character_skills WHERE character_id = p_character_id AND stat_key = p_stat_key FOR UPDATE;
    v_sp := v_sp + v_points;
    LOOP
      v_cost := public.rpg_level_cost(v_after);
      EXIT WHEN v_sp < v_cost;
      v_sp := v_sp - v_cost; v_earned := v_earned + 1; v_after := v_after + 1;
    END LOOP;
    UPDATE public.rpg_character_skills SET skill_points = v_sp, earned_levels = v_earned
     WHERE character_id = p_character_id AND stat_key = p_stat_key;
  END IF;

  SELECT agency_id INTO v_agency FROM public.rpg_characters WHERE id = p_character_id;
  INSERT INTO public.rpg_rolls (agency_id, character_id, session_id, stat_key, skill, difficulty, needed, critical_at,
                                roll, result, points_awarded, level_before, level_after, parent_roll_id, extra_pending, label)
  VALUES (v_agency, p_character_id, p_session_id, p_stat_key, v_skill, v_diff, (v_nc->>'needed')::numeric, (v_nc->>'critical')::numeric,
          v_roll, v_result, v_points, v_before, v_after, p_parent_roll_id, v_result = 'C', p_label)
  RETURNING id INTO v_id;
  IF p_parent_roll_id IS NOT NULL THEN
    UPDATE public.rpg_rolls SET extra_pending = false WHERE id = p_parent_roll_id;
  END IF;

  RETURN jsonb_build_object('roll_id', v_id, 'character_id', p_character_id, 'stat_key', p_stat_key, 'stat_name', v_stat->>'name',
    'skill', v_skill, 'difficulty', v_diff, 'needed', v_nc->'needed', 'critical', v_nc->'critical',
    'roll', v_roll, 'result', v_result, 'points', round(v_points, 1), 'level_before', v_before, 'level_after', v_after,
    'extra_pending', v_result = 'C', 'parent_roll_id', p_parent_roll_id, 'label', p_label, 'created_at', now());
END;
$function$;

-- 4. The three rule cards, updated in place. Source becomes the game master's ruling where the manual or the
--    character generator no longer says what the card says. The manual page keeps the original wording.
UPDATE public.rpg_rules SET
  body = 'Roll a d100. The result has to reach the Needed number.
Needed is the lowest die result that counts. It comes from your skill and the difficulty.

Against a fixed challenge (a wall, a lock, a jump, a sleeping or bound foe):
Needed = 100 × Difficulty ÷ (Difficulty + Skill).
*Skill 5 against difficulty 5 needs 50 or more. That lands about half the time.*
*Skill 5 against difficulty 15 needs 75 or more. Skill 15 against difficulty 5 needs 25 or more.*

Against an opponent who can act (someone defending, resisting or hiding), the difficulty is their skill, and it counts double. You are fighting their skill and their will to use it, and avoiding a hit is easier than landing one:
Needed = 100 × (2 × Their skill) ÷ (2 × Their skill + Your skill).
*Skill 5 against skill 5 needs 67 or more. That lands about one time in three.*
*Skill 10 against skill 5 needs 50 or more. Skill 5 against skill 10 needs 80 or more.*

Critical = 100 − (100 − Needed) × Critical Chance. Critical Chance is 10%.
*Needed 67: a roll of 97 or more is a critical.*
At or above Critical is a critical success (C). At or above Needed is a success (Y). Below Needed fails.
A skill of 0 needs a 100. A difficulty of 0 is no challenge: any roll succeeds.
Difficulty is 5 unless the game master sets another.',
  source = 'peter',
  updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'roll_check';

UPDATE public.rpg_rules SET
  body = 'Every roll of a skill pays skill points, whether it succeeds or fails. That includes the additional rolls after a critical roll.

Skill points = the die result × Needed ÷ 100. Needed is the lowest die result that counts on that roll (see Roll Check).
*Skill 10 against skill 5 (Needed 50): a roll of 40 pays 20 points, a roll of 90 pays 45.*
*Skill 5 against skill 10 (Needed 80): a roll of 60 misses but still pays 48. A roll of 90 pays 72.*
*Skill 5 against skill 5 (Needed 67): a roll of 90 pays about 60.*
Easy targets teach little and hard targets teach the most. A roll can never pay more than the die shows.
A skill of 0 (Needed 100) learns fastest. A difficulty of 0 (Needed 0) teaches nothing.

A skill will increase to the next level when skill points have been earned equal to 1000 times the sum of the old level AND the new level. *For example, advancing to level 12 will require 23k skill points (11k skill points + 12k skill points).* At equal skill a roll pays about 34 points on average, so level 1 to level 2 (3,000 points) takes about 90 rolls.

Characters can train in a skill by using that skill, though time and resources may limit training. *For example, hunger may set in or training with a tutor may cost money.*

Abilities, strengths, and attributes can only be increased through special means.',
  source = 'peter',
  updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'skill_gain';

UPDATE public.rpg_rules SET
  body = 'The attacker rolls once against the defender''s skill (see Roll Check: an opponent''s skill counts double). The defender does not roll.

Damage = the die result − Needed, rounded down, and at least 1 on any hit that lands. A critical prompts an additional roll, and that roll''s result adds to the damage.
*Skill 5 against skill 5 (Needed 67): a roll of 80 does 13 damage. A roll of 68 does 1.*
*Skill 10 against skill 5 (Needed 50): a roll of 90 does 40.*
*Skill 5 against skill 10 (Needed 80): a roll of 95 does 15.*
Damage comes off Physical Vitality. At 0 the character is down until healed.',
  updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'damage';

-- 5. The damage knob's label described the old two-roll reading. Same key, same value (1), label follows the ruling.
UPDATE public.rpg_settings SET label = 'Damage = (die − Needed) ÷ this, rounded down, at least 1'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'damage_divisor';

-- 6. Guards: exactly one rpg_needed, the same callers as before, and the ladder comes out right.
DO $$
DECLARE v_n integer; v_callers text; v_fixed numeric; v_opp numeric; v_10v5 numeric; v_5v10 numeric; v_s0 numeric; v_d0 numeric;
BEGIN
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rpg_needed';
  IF v_n <> 1 THEN RAISE EXCEPTION 'expected exactly one rpg_needed, found %', v_n; END IF;

  SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO v_callers
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname <> 'rpg_needed'
    AND pg_get_functiondef(p.oid) LIKE '%public.rpg_needed(%';
  IF v_callers IS DISTINCT FROM 'rpg_roll, rpg_sheet' THEN
    RAISE EXCEPTION 'rpg_needed callers changed: %', coalesce(v_callers, '(none)');
  END IF;

  PERFORM set_config('request.jwt.claims', '{"sub":"dc9a6291-6d79-410b-9870-ff5d0c81a7f0","role":"authenticated"}', true);
  v_fixed := (public.rpg_needed(5, 5)->>'needed')::numeric;
  v_opp   := (public.rpg_needed(5, 5, true)->>'needed')::numeric;
  v_10v5  := (public.rpg_needed(10, 5, true)->>'needed')::numeric;
  v_5v10  := (public.rpg_needed(5, 10, true)->>'needed')::numeric;
  v_s0    := (public.rpg_needed(0, 5, true)->>'needed')::numeric;
  v_d0    := (public.rpg_needed(5, 0, true)->>'needed')::numeric;
  IF v_fixed <> 50 OR v_opp <> 66.67 OR v_10v5 <> 50 OR v_5v10 <> 80 OR v_s0 <> 100 OR v_d0 <> 0 THEN
    RAISE EXCEPTION 'rpg_needed ladder wrong: fixed 5v5=% opposed 5v5=% 10v5=% 5v10=% s0=% d0=%', v_fixed, v_opp, v_10v5, v_5v10, v_s0, v_d0;
  END IF;
  PERFORM set_config('request.jwt.claims', '', true);
END $$;
