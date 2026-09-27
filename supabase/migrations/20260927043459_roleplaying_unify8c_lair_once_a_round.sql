-- Roleplaying unify8c: a lair action is once a round. On the fight clock a fast creature gets more turns, and a free
-- lair action on every one of them (the Bramblemaw's Grasping Roots at ticks 232 and 244) was more than the one a
-- round it had before. rpg_session_participants.lair_round records the round its lair last acted.

ALTER TABLE public.rpg_session_participants ADD COLUMN IF NOT EXISTS lair_round integer;

CREATE FUNCTION pg_temp.rep(p_def text, p_old text, p_new text, p_label text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n integer := (length(p_def) - length(replace(p_def, p_old, ''))) / length(p_old);
BEGIN
  IF n <> 1 THEN RAISE EXCEPTION 'anchor % found % times', p_label, n; END IF;
  RETURN replace(p_def, p_old, p_new);
END $f$;

DO $do$
DECLARE v text;
BEGIN
  v := pg_get_functiondef('public.rpg_act(uuid,uuid[],text,uuid,text,numeric,integer,text)'::regprocedure);
  v := pg_temp.rep(v, $a$    IF v_act.kind = 'trait' THEN RAISE EXCEPTION '% is a trait, not an action', v_act.name; END IF;$a$,
$b$    IF v_act.kind = 'trait' THEN RAISE EXCEPTION '% is a trait, not an action', v_act.name; END IF;
    IF v_act.kind = 'lair' AND v_actor.lair_round IS NOT DISTINCT FROM v_s.round THEN RAISE EXCEPTION '% has used its lair this round', v_actor.name; END IF;$b$, 'act lair check');
  v := pg_temp.rep(v, $a$       SET legendary_left = legendary_left - CASE WHEN v_act.kind = 'legendary' THEN v_act.legendary_cost ELSE 0 END$a$,
$b$       SET legendary_left = legendary_left - CASE WHEN v_act.kind = 'legendary' THEN v_act.legendary_cost ELSE 0 END,
           lair_round = CASE WHEN v_act.kind = 'lair' THEN v_s.round ELSE lair_round END$b$, 'act lair mark');
  EXECUTE v;

  v := pg_get_functiondef('public.rpg_act_square(uuid,integer,integer,uuid)'::regprocedure);
  v := pg_temp.rep(v, $a$    IF v_akind = 'legendary' AND v_actor.legendary_left < v_act.legendary_cost THEN$a$,
$b$    IF v_akind = 'lair' AND v_actor.lair_round IS NOT DISTINCT FROM v_s.round THEN RAISE EXCEPTION '% has used its lair this round', v_actor.name; END IF;
    IF v_akind = 'legendary' AND v_actor.legendary_left < v_act.legendary_cost THEN$b$, 'square lair check');
  v := pg_temp.rep(v, $a$    IF v_akind = 'legendary' THEN
      UPDATE public.rpg_session_participants SET legendary_left$a$,
$b$    IF v_akind = 'lair' THEN UPDATE public.rpg_session_participants SET lair_round = v_s.round WHERE id = p_actor_id; END IF;
    IF v_akind = 'legendary' THEN
      UPDATE public.rpg_session_participants SET legendary_left$b$, 'square lair mark');
  EXECUTE v;

  v := pg_get_functiondef('public.rpg_session_auto_turn(uuid)'::regprocedure);
  v := pg_temp.rep(v, $a$WHERE a.creature_id = v_p.creature_id AND a.kind = 'lair' AND public.rpg_action_ready(v_p.id, a.id) LOOP$a$,
                      $b$WHERE a.creature_id = v_p.creature_id AND a.kind = 'lair' AND v_p.lair_round IS DISTINCT FROM v_s.round AND public.rpg_action_ready(v_p.id, a.id) LOOP$b$, 'auto lair');
  v := pg_temp.rep(v, $a$-- anything (Briar Shift goes on a square).$a$, $b$-- anything, once a round (Briar Shift goes on a square).$b$, 'auto comment');
  EXECUTE v;

  v := pg_get_functiondef('public.rpg_action_text(uuid,numeric)'::regprocedure);
  v := pg_temp.rep(v, $a$  IF a.kind IN ('action', 'bonus_action') AND coalesce(a.beats, 0) > 0 THEN$a$,
$b$  IF a.kind = 'lair' THEN v_parts := v_parts || 'Once a round'::text; END IF;
  IF a.kind IN ('action', 'bonus_action') AND coalesce(a.beats, 0) > 0 THEN$b$, 'text lair');
  EXECUTE v;

  SELECT body INTO v FROM public.rpg_rules WHERE key = 'turn_order';
  v := pg_temp.rep(v, $a$up to its number a round.$a$, $b$up to its number a round. A creature's lair action is free and comes once a round, on its own turn.$b$, 'rule lair');
  UPDATE public.rpg_rules SET body = v WHERE key = 'turn_order';
END $do$;

