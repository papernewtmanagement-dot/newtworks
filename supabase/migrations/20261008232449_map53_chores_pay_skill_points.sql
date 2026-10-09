ALTER TABLE public.rpg_characters ADD COLUMN IF NOT EXISTS family_awards jsonb NOT NULL DEFAULT '{}'::jsonb;

INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
 ('126794dd-25ff-47d2-a436-724499733365', 'family_points_per_dollar', 100, 'Chores: skill points a character earns for each dollar of chore pay on a day the kid finishes the whole list (100 = one point per cent; a 5 dollar day is 500 points)')
ON CONFLICT (agency_id, key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.family_day_award(p_kid_id uuid, p_date date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The ONE place chores pay the game. A kid's character earns skill points equal to the chore pay of a day whose whole
-- list is done (every chore, extras aside, done, checked, excused or carried; the same rule the Family page uses for the
-- day-done dance), times family_points_per_dollar (100: a 5.00 day is 500 points). The points are spread over the skills
-- the character rolled that day, in proportion to how often each was rolled; with no rolls that day, over the 7 days
-- before; with none then, over its 5 most recently rolled skills; with none ever, nothing is paid yet.
-- The split is fixed the first time the day pays (rpg_characters.family_awards, keyed by day), and each call after moves
-- the points to match the day as it stands now: a chore that flips to missed, or an undone chore, takes the points back
-- (a skill's bank can go below zero and later points fill it first); more pay gives the difference.
-- A skill's points go through rpg_add_skill_points, the one writer of banked points, and the first payment to a skill
-- on a day also flows down the skill tree through rpg_trickle like a roll; a take-back removes only the skill's own points.
-- Called by the trigger on family_chore_log, so every route that writes a chore (tap, burpee run, math, sweep, close) pays alike.
DECLARE
  v_char  uuid;
  v_have  jsonb;
  v_key   text := p_date::text;
  v_done  boolean;
  v_pay   numeric;
  v_target numeric;
  v_w     jsonb;
  v_given jsonb;
  v_tr    jsonb;
  v_wsum  numeric;
  v_stat  text;
  v_want  numeric;
  v_delta numeric;
  v_now   numeric;
BEGIN
  SELECT c.id, c.family_awards -> v_key INTO v_char, v_have
    FROM public.rpg_characters c
   WHERE c.kid_id = p_kid_id AND c.is_active AND NOT c.is_npc
   ORDER BY c.created_at LIMIT 1;
  IF v_char IS NULL THEN RETURN 0; END IF;
  IF v_have IS NULL AND EXISTS (SELECT 1 FROM public.family_chore_log l
       WHERE l.kid_id = p_kid_id AND l.occurrence_date = p_date AND l.status IN ('missed', 'false_claim')) THEN
    RETURN 0;
  END IF;
  SELECT count(*) FILTER (WHERE b.frequency <> 'extra') > 0
         AND bool_and(b.frequency = 'extra' OR coalesce(b.status IN ('claimed', 'verified', 'excused', 'carried'), false)),
         coalesce(sum(b.amount) FILTER (WHERE b.status IN ('claimed', 'verified')), 0)
    INTO v_done, v_pay
    FROM public.family_week_board(p_kid_id, public.family_week_start(p_date)) b WHERE b.day = p_date;
  v_target := CASE WHEN coalesce(v_done, false) THEN
      round(greatest(v_pay, 0) * (SELECT s.value FROM public.rpg_settings s
        WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'family_points_per_dollar'))
    ELSE 0 END;
  IF v_have IS NULL AND v_target = 0 THEN RETURN 0; END IF;
  v_w := coalesce(v_have -> 'weights', '{}'::jsonb);
  v_given := coalesce(v_have -> 'given', '{}'::jsonb);
  v_tr := coalesce(v_have -> 'trickled', '{}'::jsonb);
  IF v_w = '{}'::jsonb THEN
    SELECT coalesce(jsonb_object_agg(s.stat_key, s.n), '{}'::jsonb) INTO v_w FROM (
      SELECT r.stat_key, count(*) AS n FROM public.rpg_rolls r
       WHERE r.character_id = v_char AND (r.created_at AT TIME ZONE 'America/Chicago')::date = p_date GROUP BY r.stat_key) s;
    IF v_w = '{}'::jsonb THEN
      SELECT coalesce(jsonb_object_agg(s.stat_key, s.n), '{}'::jsonb) INTO v_w FROM (
        SELECT r.stat_key, count(*) AS n FROM public.rpg_rolls r
         WHERE r.character_id = v_char AND (r.created_at AT TIME ZONE 'America/Chicago')::date >= p_date - 7
           AND (r.created_at AT TIME ZONE 'America/Chicago')::date < p_date GROUP BY r.stat_key) s;
    END IF;
    IF v_w = '{}'::jsonb THEN
      SELECT coalesce(jsonb_object_agg(s.stat_key, 1), '{}'::jsonb) INTO v_w FROM (
        SELECT r.stat_key FROM public.rpg_rolls r WHERE r.character_id = v_char
         GROUP BY r.stat_key ORDER BY max(r.created_at) DESC LIMIT 5) s;
    END IF;
  END IF;
  SELECT coalesce(sum(e.value::numeric), 0) INTO v_wsum FROM jsonb_each_text(v_w) e;
  IF v_wsum <= 0 THEN RETURN 0; END IF;
  FOR v_stat IN SELECT e.key FROM jsonb_each_text(v_w) e ORDER BY e.key LOOP
    v_want  := round(v_target * (v_w ->> v_stat)::numeric / v_wsum);
    v_delta := v_want - coalesce((v_given ->> v_stat)::numeric, 0);
    IF v_delta <> 0 THEN
      v_now := coalesce((public.rpg_sheet_values(v_char) -> 'values' ->> v_stat)::numeric, 0);
      PERFORM public.rpg_add_skill_points(v_char, v_stat, v_delta, v_now);
      IF v_delta > 0 AND NOT (v_tr ? v_stat) THEN
        PERFORM public.rpg_trickle(v_char, v_stat, v_delta);
        v_tr := v_tr || jsonb_build_object(v_stat, true);
      END IF;
      v_given := v_given || jsonb_build_object(v_stat, v_want);
    END IF;
  END LOOP;
  UPDATE public.rpg_characters SET family_awards = family_awards
      || jsonb_build_object(v_key, jsonb_build_object('weights', v_w, 'given', v_given, 'trickled', v_tr))
   WHERE id = v_char;
  RETURN v_target::integer;
END;
$function$;

CREATE OR REPLACE FUNCTION public.family_day_points(p_kid_id uuid, p_date date)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What the kid's character has been paid for that day's chores (the finish-the-day popup shows it).
  SELECT public.require_login('family');
  SELECT coalesce((SELECT sum(g.value::numeric) FROM public.rpg_characters c,
           jsonb_each_text(coalesce(c.family_awards -> p_date::text -> 'given', '{}'::jsonb)) g
          WHERE c.id = (SELECT c2.id FROM public.rpg_characters c2 WHERE c2.kid_id = p_kid_id AND c2.is_active AND NOT c2.is_npc
                         ORDER BY c2.created_at LIMIT 1)), 0)::integer;
$function$;

CREATE OR REPLACE FUNCTION public.family_chore_log_award()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- After any chore write: pay or take back the day's skill points (family_day_award). A game problem never blocks a chore.
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.status IS NOT DISTINCT FROM OLD.status AND NEW.amount IS NOT DISTINCT FROM OLD.amount THEN
    RETURN NEW;
  END IF;
  BEGIN
    PERFORM public.family_day_award(coalesce(NEW.kid_id, OLD.kid_id), coalesce(NEW.occurrence_date, OLD.occurrence_date));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'family_day_award failed: %', SQLERRM;
  END;
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE TRIGGER family_chore_log_award AFTER INSERT OR UPDATE OR DELETE ON public.family_chore_log
  FOR EACH ROW EXECUTE FUNCTION public.family_chore_log_award();

REVOKE ALL ON FUNCTION public.family_day_award(uuid, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.family_chore_log_award() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.family_day_award(uuid, date) TO service_role;
REVOKE ALL ON FUNCTION public.family_day_points(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.family_day_points(uuid, date) TO authenticated, service_role;
