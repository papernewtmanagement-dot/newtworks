-- Roleplaying unify7c: two fixes found in the grid test. A walking creature, among squares equally close to its
-- target by board distance, now takes the one closest in a straight line (E1 toward Zaboo on E8 goes to E4, not B4).
-- The start-of-turn line said "gets up" for every effect that ends then; it now says that only for one that kept
-- them from acting (Knocked down), and "is no longer Dug in" for the rest.

CREATE OR REPLACE FUNCTION public.rpg_step_target(p_participant_id uuid, p_budget integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where the site walks a creature: toward the nearest character still standing, as far as p_budget of path cost takes
-- it (rpg_grid_costs). It picks the reachable square closest to any such character by board distance, then by
-- straight line, then the cheaper one, and only if that is closer than where it stands; nothing when a character is
-- already next to it. The Bramblemaw on E1 with 3 to spend and Zaboo on E8 goes to E4.
DECLARE v_p record; v_now integer; v_tx integer[]; v_ty integer[];
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.pos_x IS NULL OR coalesce(p_budget, 0) <= 0 THEN RETURN NULL; END IF;
  SELECT array_agg(t.pos_x), array_agg(t.pos_y) INTO v_tx, v_ty
    FROM public.rpg_session_participants t
   WHERE t.session_id = v_p.session_id AND t.creature_id IS NULL AND t.pos_x IS NOT NULL
     AND (public.rpg_participant_vitality(t.id)->>'left')::integer > 0;
  IF v_tx IS NULL THEN RETURN NULL; END IF;
  SELECT min(greatest(abs(tx - v_p.pos_x), abs(ty - v_p.pos_y))) INTO v_now FROM unnest(v_tx, v_ty) AS u(tx, ty);
  IF v_now <= 1 THEN RETURN NULL; END IF;
  RETURN (SELECT jsonb_build_object('x', g.x, 'y', g.y, 'cost', g.cost)
            FROM public.rpg_grid_costs(p_participant_id) g,
                 LATERAL (SELECT min(greatest(abs(tx - g.x), abs(ty - g.y))) AS dist,
                                 min((tx - g.x) * (tx - g.x) + (ty - g.y) * (ty - g.y)) AS line
                            FROM unnest(v_tx, v_ty) AS u(tx, ty)) m
           WHERE g.cost > 0 AND g.cost <= p_budget AND m.dist < v_now
           ORDER BY m.dist, m.line, g.cost, g.y, g.x LIMIT 1);
END;
$function$;

CREATE FUNCTION pg_temp.rep(p_def text, p_old text, p_new text, p_label text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n integer := (length(p_def) - length(replace(p_def, p_old, ''))) / length(p_old);
BEGIN
  IF n <> 1 THEN RAISE EXCEPTION 'anchor % found % times', p_label, n; END IF;
  RETURN replace(p_def, p_old, p_new);
END $f$;

DO $do$
DECLARE v text := pg_get_functiondef('public.rpg_session_next_turn(uuid)'::regprocedure);
BEGIN
  v := pg_temp.rep(v, $a$  FOR v_a IN SELECT e->>'name' AS ename FROM jsonb_array_elements(v_next.effects) e WHERE e->>'clear' = 'turn_start' LOOP$a$,
                      $b$  FOR v_a IN SELECT e->>'name' AS ename, coalesce((e->>'cannot_act')::boolean, false) AS held FROM jsonb_array_elements(v_next.effects) e WHERE e->>'clear' = 'turn_start' LOOP$b$, 'next turn_start loop');
  v := pg_temp.rep(v, $a$v_next.name || ' gets up. No longer ' || v_a.ename || '.'$a$,
                      $b$v_next.name || CASE WHEN v_a.held THEN ' gets up. No longer ' ELSE ' is no longer ' END || v_a.ename || '.'$b$, 'next gets up');
  EXECUTE v;
END $do$;

