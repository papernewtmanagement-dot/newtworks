-- Family timers, Peter 2026-09-23 (answers to the four timer questions):
-- 1. Cancel: anyone on the family screen can cancel a running timer, so a timer
--    started by accident can be taken back (it was parents only).
-- 2. Stopping the burpee timer checks off the Burpees chore the run was for
--    (morning, then afternoon), the same as tapping Done. Only a run that counts
--    (no quicker than 1.5 seconds a burpee) checks it off, so a start and stop by
--    accident checks nothing off. Over the time limit still checks it off: the
--    burpees got done, the run just earns no point.
-- 3. The burpee timer shows only while a Burpees set is still open today. Once both
--    sets are done it goes away, so extra runs can't pile up points for the week.
--    A set follows the same order as tapping Done: the afternoon set can't start
--    until the morning chores are finished.
-- Points stay the best tier only (not added up) and going over the burpee limit
-- stays no fine, just no point.

-- The Burpees set a run is for: the first one of the day with nothing logged on it yet
-- (morning, then afternoon). NULL once every set is done. One function for the timer
-- list, start and stop.
CREATE OR REPLACE FUNCTION public.family_next_burpee_chore(p_kid_id uuid, p_date date)
RETURNS uuid LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT c.id
    FROM public.family_chores c
   WHERE c.kid_id = p_kid_id AND c.is_burpees
     AND (c.active_from IS NULL OR c.active_from <= p_date) AND (c.active_to IS NULL OR c.active_to >= p_date)
     AND NOT EXISTS (SELECT 1 FROM public.family_chore_log g WHERE g.chore_id = c.id AND g.occurrence_date = p_date)
   ORDER BY CASE c.part_of_day WHEN 'morning' THEN 1 WHEN 'afternoon' THEN 2 WHEN 'evening' THEN 3 ELSE 4 END
   LIMIT 1;
$$;
REVOKE EXECUTE ON FUNCTION public.family_next_burpee_chore(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.family_next_burpee_chore(uuid, date) TO authenticated, service_role;

-- Which Burpees chore a burpee run is for, fixed when it starts.
ALTER TABLE public.family_timers ADD COLUMN IF NOT EXISTS chore_id uuid REFERENCES public.family_chores(id) ON DELETE SET NULL;

-- Timers. Which timers a kid has, and the one running of each kind.
-- Burpees: while a Burpees set is still open today (or a run is going); shows all day.
-- Shower: kids with shower minutes set; the screen shows it from 5 pm Central (shows_from).
CREATE OR REPLACE FUNCTION public.family_timer_list(p_kid_id uuid)
RETURNS TABLE(kind text, icon text, minutes integer, shows_from time, running_id uuid, started_at timestamptz, limit_seconds integer)
LANGUAGE sql STABLE SET search_path = public AS $$
  WITH today AS (SELECT (now() AT TIME ZONE 'America/Chicago')::date AS d),
  kinds AS (
    SELECT 'burpees'::text AS kind, '💪'::text AS icon, s.burpee_minutes::int AS minutes, NULL::time AS shows_from, 1 AS ord
      FROM public.family_kids k
      JOIN public.family_settings s ON s.agency_id = k.agency_id
      CROSS JOIN today
     WHERE k.id = p_kid_id AND k.is_active
       AND (public.family_next_burpee_chore(k.id, today.d) IS NOT NULL
            OR EXISTS (SELECT 1 FROM public.family_timers r WHERE r.kid_id = k.id AND r.kind = 'burpees' AND r.ended_at IS NULL))
    UNION ALL
    SELECT 'shower', '🚿', k.shower_minutes::int, time '17:00', 2
      FROM public.family_kids k
     WHERE k.id = p_kid_id AND k.is_active AND k.shower_minutes IS NOT NULL
  )
  SELECT x.kind, x.icon, x.minutes, x.shows_from, t.id, t.started_at, t.limit_seconds
    FROM kinds x
    LEFT JOIN public.family_timers t ON t.kid_id = p_kid_id AND t.kind = x.kind AND t.ended_at IS NULL
   ORDER BY x.ord;
$$;

CREATE OR REPLACE FUNCTION public.family_timer_start(p_kid_id uuid, p_kind text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_min int; v_chore uuid; v_count int; v_lock text; v_today date := (now() AT TIME ZONE 'America/Chicago')::date; v_row public.family_timers;
BEGIN
  IF NOT (public.family_is_parent() OR public.auth_is_family()) THEN RAISE EXCEPTION 'Not allowed.'; END IF;
  SELECT l.minutes INTO v_min FROM public.family_timer_list(p_kid_id) l WHERE l.kind = p_kind;
  IF p_kind = 'burpees' AND NOT EXISTS (SELECT 1 FROM public.family_timers r WHERE r.kid_id = p_kid_id AND r.kind = 'burpees' AND r.ended_at IS NULL) THEN
    -- The set this run is for, and how many burpees that set owes.
    v_chore := public.family_next_burpee_chore(p_kid_id, v_today);
    IF v_chore IS NULL THEN RAISE EXCEPTION 'Burpees are all done for today.'; END IF;
    v_lock := public.family_part_locked(p_kid_id, v_today, (SELECT c.part_of_day FROM public.family_chores c WHERE c.id = v_chore));
    IF v_lock IS NOT NULL THEN RAISE EXCEPTION 'Finish % first.', v_lock; END IF;
    v_count := public.family_burpees_owed(v_chore, v_today);
  END IF;
  IF v_min IS NULL THEN RAISE EXCEPTION 'No % timer for this kid.', p_kind; END IF;
  INSERT INTO public.family_timers (kid_id, kind, limit_seconds, burpee_count, chore_id)
  VALUES (p_kid_id, p_kind, v_min * 60, v_count, v_chore)
  ON CONFLICT (kid_id, kind) WHERE ended_at IS NULL DO NOTHING;
  SELECT * INTO v_row FROM public.family_timers WHERE kid_id = p_kid_id AND kind = p_kind AND ended_at IS NULL;
  RETURN to_jsonb(v_row);
END $$;

CREATE OR REPLACE FUNCTION public.family_timer_cancel(p_kid_id uuid, p_kind text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- Anyone on the family screen can cancel, so a timer started by accident can be taken back.
  IF NOT (public.family_is_parent() OR public.auth_is_family()) THEN RAISE EXCEPTION 'Not allowed.'; END IF;
  DELETE FROM public.family_timers WHERE kid_id = p_kid_id AND kind = p_kind AND ended_at IS NULL;
END $$;

-- Stop: works out a shower fine, or a burpee run's points and checks off its Burpees chore.
CREATE OR REPLACE FUNCTION public.family_timer_stop(p_kid_id uuid, p_kind text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row public.family_timers; v_secs int; v_over int; v_fine numeric; v_rate numeric; v_ledger uuid; v_res jsonb;
        v_day date; v_chore uuid; v_counted boolean; v_checked boolean := false; v_check_error text;
BEGIN
  IF NOT (public.family_is_parent() OR public.auth_is_family()) THEN RAISE EXCEPTION 'Not allowed.'; END IF;
  SELECT * INTO v_row FROM public.family_timers WHERE kid_id = p_kid_id AND kind = p_kind AND ended_at IS NULL FOR UPDATE;
  IF v_row.id IS NULL THEN RAISE EXCEPTION 'That timer is not running.'; END IF;
  v_secs := floor(extract(epoch FROM now() - v_row.started_at))::int;
  v_over := GREATEST(0, v_secs - v_row.limit_seconds);
  -- Shower: every second over costs the per-minute fine / 60, to the cent. A given fine, so it settles at the close-out.
  IF p_kind = 'shower' THEN
    SELECT COALESCE(shower_fine_per_minute, 1.00) INTO v_rate FROM public.family_settings WHERE agency_id = v_row.agency_id;
    v_fine := round(v_over * COALESCE(v_rate, 1.00) / 60.0, 2);
    IF v_fine > 0 THEN
      INSERT INTO public.family_ledger (agency_id, kid_id, entry_date, bucket, kind, amount, note)
      VALUES (v_row.agency_id, p_kid_id, (v_row.started_at AT TIME ZONE 'America/Chicago')::date, 'spend', 'fine', -v_fine,
              'Shower ' || (v_secs / 60) || ':' || lpad((v_secs % 60)::text, 2, '0') || ' (' || (v_over / 60) || ':' || lpad((v_over % 60)::text, 2, '0') || ' over)')
      RETURNING id INTO v_ledger;
    END IF;
  END IF;
  UPDATE public.family_timers SET ended_at = now(), seconds = v_secs, over_seconds = v_over, fine = v_fine, ledger_id = v_ledger
   WHERE id = v_row.id RETURNING * INTO v_row;
  v_res := to_jsonb(v_row);
  IF p_kind = 'burpees' THEN
    SELECT v_res || jsonb_build_object('points', s.points, 'prior_best', s.prior_best, 'counted', s.counted), s.counted
      INTO v_res, v_counted FROM public.family_burpee_sessions() s WHERE s.id = v_row.id;
    -- The run checks off its Burpees chore, the same as tapping Done, if nothing is logged on it yet.
    -- A run too quick to count (started and stopped by accident) checks nothing off.
    IF v_counted THEN
      v_day := (v_row.started_at AT TIME ZONE 'America/Chicago')::date;
      v_chore := COALESCE(v_row.chore_id, public.family_next_burpee_chore(p_kid_id, v_day));
      -- A set logged some other way while the run was going stays as it was.
      IF v_chore IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.family_chore_log g WHERE g.chore_id = v_chore AND g.occurrence_date = v_day) THEN
        BEGIN
          PERFORM public.family_set_status(v_chore, v_day, 'claimed', NULL, p_kid_id, NULL);
          v_checked := true;
        EXCEPTION WHEN raise_exception THEN
          v_check_error := SQLERRM;  -- e.g. "Finish Morning first." The run still counts.
        END;
      END IF;
    END IF;
    v_res := v_res || jsonb_build_object('checked_off', v_checked, 'check_error', v_check_error);
  END IF;
  RETURN v_res;
END $$;

