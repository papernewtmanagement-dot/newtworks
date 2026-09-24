-- Family, Peter 2026-09-24.
--
-- 1. Every other week. A weekly chore can come every other week: family_chores.every_weeks
--    (1 every week, 2 every other week) and start_week (a Saturday that starts a chore week it
--    is due). family_occurrence_date stays the one due-date rule. An off week has no occurrence
--    (NULL), so the board and the missed-chore sweep skip it, "Could earn" (family_balances)
--    leaves it out, and family_set_status refuses it. The Office chores (Becca's two and
--    Bella's three, due Thursday) are every other week from this week: due Sep 19-25, off
--    Sep 26-Oct 2, due again Oct 3-9.
--
-- 2. Continue. A parent can pick a timer back up when a kid stopped it by accident
--    (family_timer_continue). It undoes the stop: the run keeps its start time, so the clock
--    counts as if it was never stopped and a run can never come out faster than it really was.
--    The stop now saves the Burpees check-off it made (family_timers.checked_log_id), so
--    Continue takes back exactly that row, and a shower fine by its ledger id. Only the kid's
--    latest run today, and only while its time limit lasts (family_timer_continuable is the one
--    rule). family_timer_list adds can_start, and continue_id, continue_seconds and
--    continue_until for parents only.
--
-- 3. Stopped early. family_timers.stopped_early: a parent says the run was stopped before the
--    set was done, so its time is not real. It earns 1 point for finishing and never counts as
--    a best. Elliott's run this morning was that (80 burpees in 2:08, half his usual time). It
--    had scored 5 as a new best and set a best he could never beat. Peter: not a best, 1 point.

-- 1. Every other week ---------------------------------------------------------------------
ALTER TABLE public.family_chores ADD COLUMN IF NOT EXISTS every_weeks smallint NOT NULL DEFAULT 1;
ALTER TABLE public.family_chores ADD COLUMN IF NOT EXISTS start_week date;
ALTER TABLE public.family_chores DROP CONSTRAINT IF EXISTS family_chores_every_weeks_check;
ALTER TABLE public.family_chores ADD CONSTRAINT family_chores_every_weeks_check
  CHECK (every_weeks = 1 OR (every_weeks BETWEEN 2 AND 4 AND frequency = 'weekly'
                             AND start_week IS NOT NULL AND extract(dow FROM start_week) = 6));

CREATE OR REPLACE FUNCTION public.family_occurrence_date(p_chore_id uuid, p_date date)
RETURNS date LANGUAGE sql STABLE AS $$
  -- The one due-date rule. A weekly chore is due on its day of the chore week (Sat-Fri).
  -- An every-other-week chore has no occurrence at all in its off week (Peter 2026-09-24).
  SELECT CASE WHEN c.frequency <> 'weekly' THEN p_date
              WHEN c.every_weeks > 1
               AND ((public.family_week_start(p_date) - c.start_week) / 7) % c.every_weeks <> 0 THEN NULL
              ELSE public.family_week_start(p_date) + ((COALESCE(c.due_dow, 5) + 1) % 7) END
  FROM public.family_chores c WHERE c.id = p_chore_id;
$$;

CREATE OR REPLACE FUNCTION public.family_set_status(p_chore_id uuid, p_occurrence_date date, p_status text, p_note text DEFAULT NULL::text, p_kid_id uuid DEFAULT NULL::uuid, p_slot smallint DEFAULT NULL::smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE v_c public.family_chores; v_occ date; v_cur text; v_cur_kid uuid; v_kid uuid; v_slot smallint;
        v_parent boolean := public.family_is_parent(); v_count int; v_row public.family_chore_log; v_lock text;
BEGIN
  SELECT * INTO v_c FROM public.family_chores WHERE id = p_chore_id;
  IF v_c.id IS NULL THEN RAISE EXCEPTION 'Chore not found.'; END IF;
  v_occ := public.family_occurrence_date(p_chore_id, p_occurrence_date);
  -- An every-other-week chore in its off week (Peter 2026-09-24).
  IF v_occ IS NULL THEN RAISE EXCEPTION 'That chore is off this week.'; END IF;
  IF p_status = 'picked' AND v_c.frequency = 'extra' AND v_c.repeat_days = 0 AND p_slot IS NULL THEN
    SELECT COALESCE(max(slot), 0) + 1 INTO v_slot FROM public.family_chore_log WHERE chore_id = p_chore_id AND occurrence_date = v_occ;
  ELSE
    v_slot := COALESCE(p_slot, 1);
  END IF;
  SELECT status, kid_id INTO v_cur, v_cur_kid FROM public.family_chore_log
   WHERE chore_id = p_chore_id AND occurrence_date = v_occ AND slot = v_slot;
  IF v_c.frequency = 'extra' AND v_cur_kid IS NOT NULL AND p_kid_id IS NOT NULL AND v_cur_kid <> p_kid_id THEN
    RAISE EXCEPTION 'Someone else already took that one.';
  END IF;
  v_kid := COALESCE(v_c.kid_id, v_cur_kid, p_kid_id);
  IF v_kid IS NULL THEN RAISE EXCEPTION 'Pick a kid first.'; END IF;
  IF v_c.frequency = 'extra' AND p_status IN ('missed','false_claim','excused','carried') THEN
    RAISE EXCEPTION 'Extra chores are never fined. Undo it instead.';
  END IF;
  IF NOT v_parent THEN
    IF p_status IS NULL AND v_cur IS DISTINCT FROM 'picked' THEN RAISE EXCEPTION 'Only a parent can undo that.'; END IF;
    IF p_status IS NOT NULL AND p_status NOT IN ('claimed','missed','picked') THEN RAISE EXCEPTION 'Only a parent can do that.'; END IF;
    IF v_cur IN ('missed','false_claim','excused','verified','carried') THEN RAISE EXCEPTION 'Only a parent can change that.'; END IF;
  END IF;
  IF p_status = 'carried' AND NOT v_c.is_burpees THEN RAISE EXCEPTION 'Only burpees can be carried.'; END IF;
  IF p_status = 'picked' AND v_c.frequency <> 'extra' THEN RAISE EXCEPTION 'Only extra chores can be picked.'; END IF;
  IF v_c.frequency = 'daily' AND v_cur IS NULL
     AND (p_status IN ('claimed','carried') OR (p_status = 'missed' AND NOT v_parent)) THEN
    v_lock := public.family_part_locked(v_kid, v_occ, v_c.part_of_day);
    IF v_lock IS NOT NULL THEN RAISE EXCEPTION 'Finish % first.', v_lock; END IF;
  END IF;
  IF p_status IS NULL THEN
    DELETE FROM public.family_chore_log WHERE chore_id = p_chore_id AND occurrence_date = v_occ AND slot = v_slot;
    RETURN jsonb_build_object('cleared', true);
  END IF;
  IF p_status = 'carried' THEN v_count := public.family_burpees_owed(p_chore_id, v_occ); END IF;
  INSERT INTO public.family_chore_log (agency_id, chore_id, kid_id, occurrence_date, slot, status, amount, note, updated_by, burpee_count)
  VALUES (v_c.agency_id, p_chore_id, v_kid, v_occ, v_slot, p_status, public.family_log_amount(p_chore_id, p_status, v_occ), p_note, auth.uid(), v_count)
  ON CONFLICT (chore_id, occurrence_date, slot) DO UPDATE
    SET status = EXCLUDED.status, amount = EXCLUDED.amount,
        note = COALESCE(EXCLUDED.note, public.family_chore_log.note),
        updated_by = EXCLUDED.updated_by, burpee_count = EXCLUDED.burpee_count, updated_at = now()
  RETURNING * INTO v_row;
  RETURN to_jsonb(v_row);
END $function$;

CREATE OR REPLACE FUNCTION public.family_balances(p_week_start date DEFAULT NULL::date)
 RETURNS TABLE(kid_id uuid, name text, spend numeric, tithe numeric, invest numeric, pending_pay numeric, week_earned numeric, week_fines numeric, week_spent numeric, week_possible numeric, next_close date)
 LANGUAGE sql
 STABLE
AS $function$
  WITH t AS (SELECT (now() AT TIME ZONE 'America/Chicago')::date AS today),
  wk AS (SELECT COALESCE(p_week_start, public.family_week_start(t.today)) AS ws FROM t),
  la AS (
    SELECT l.kid_id, public.family_entry_amount(l.chore_id, l.kid_id, l.status, l.occurrence_date, l.amount) AS amount
    FROM public.family_chore_log l, wk WHERE l.occurrence_date BETWEEN wk.ws AND wk.ws + 6
  ),
  tw AS (
    SELECT la.kid_id, sum(la.amount) FILTER (WHERE la.amount > 0) AS earned, sum(la.amount) FILTER (WHERE la.amount < 0) AS fines
    FROM la GROUP BY 1
  ),
  lw AS (
    SELECT g.kid_id, sum(g.amount) FILTER (WHERE g.kind = 'fine') AS fines, sum(g.amount) FILTER (WHERE g.kind = 'expense') AS spent
    FROM public.family_ledger g, wk WHERE g.entry_date BETWEEN wk.ws AND wk.ws + 6 GROUP BY 1
  ),
  possible AS (
    -- An every-other-week chore in its off week is not due, so it cannot be earned (Peter 2026-09-24).
    SELECT c.kid_id, sum(c.pay * CASE WHEN c.frequency = 'daily' THEN 7 ELSE 1 END) AS amt
    FROM public.family_chores c, wk
    WHERE c.frequency IN ('daily','weekly') AND c.active_from <= wk.ws + 6 AND (c.active_to IS NULL OR c.active_to >= wk.ws)
      AND (c.frequency = 'daily' OR public.family_occurrence_date(c.id, wk.ws) IS NOT NULL)
    GROUP BY 1
  )
  SELECT k.id, k.name, m.spend, m.tithe, m.invest, m.pending,
         COALESCE(tw.earned, 0), COALESCE(tw.fines, 0) + COALESCE(lw.fines, 0), COALESCE(lw.spent, 0), COALESCE(p.amt, 0),
         (SELECT min(w::date) FROM generate_series(public.family_week_start(k.tracking_start), public.family_week_start(t.today) - 7, interval '7 days') w
          WHERE NOT EXISTS (SELECT 1 FROM public.family_weeks f WHERE f.kid_id = k.id AND f.week_start = w::date))
  FROM public.family_kids k
  CROSS JOIN t
  CROSS JOIN LATERAL public.family_kid_money(k.id, public.family_week_start(t.today)) m
  LEFT JOIN tw ON tw.kid_id = k.id
  LEFT JOIN lw ON lw.kid_id = k.id
  LEFT JOIN possible p ON p.kid_id = k.id
  WHERE k.is_active
  ORDER BY k.sort_order;
$function$;

-- 2 and 3. Timers ---------------------------------------------------------------------------
ALTER TABLE public.family_timers ADD COLUMN IF NOT EXISTS checked_log_id uuid REFERENCES public.family_chore_log(id) ON DELETE SET NULL;
ALTER TABLE public.family_timers ADD COLUMN IF NOT EXISTS stopped_early boolean NOT NULL DEFAULT false;

DROP FUNCTION IF EXISTS public.family_burpee_points(integer, integer, integer, integer);
CREATE OR REPLACE FUNCTION public.family_burpee_points(p_seconds integer, p_limit integer, p_count integer, p_prior_best integer, p_stopped_early boolean DEFAULT false)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  -- Highest tier only: 5 beats the kid's own best, 3 within 10% of it, 2 in half the limit or
  -- less, 1 under the limit, 0 over the limit or quicker than 1.5 s a burpee (Peter 2026-09-22/23).
  -- A run a parent marked stopped early earns the 1 point for finishing and nothing more,
  -- because its time is not real (Peter 2026-09-24).
  SELECT CASE
    WHEN p_stopped_early THEN 1
    WHEN p_seconds IS NULL OR p_limit IS NULL OR p_seconds > p_limit THEN 0
    WHEN NOT public.family_burpee_counts(p_seconds, p_count) THEN 0
    WHEN p_prior_best IS NOT NULL AND p_seconds < p_prior_best THEN 5
    WHEN p_prior_best IS NOT NULL AND p_seconds <= p_prior_best * 1.1 THEN 3
    WHEN p_seconds * 2 <= p_limit THEN 2
    ELSE 1 END;
$$;
REVOKE EXECUTE ON FUNCTION public.family_burpee_points(integer, integer, integer, integer, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.family_burpee_points(integer, integer, integer, integer, boolean) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.family_burpee_sessions()
RETURNS TABLE(id uuid, kid_id uuid, on_date date, started_at timestamptz, seconds integer, limit_seconds integer, burpee_count integer, counted boolean, prior_best integer, points integer)
LANGUAGE sql STABLE SET search_path = public AS $$
  -- counted = the run's time counts: not too quick (family_burpee_counts) and not marked
  -- stopped early by a parent (Peter 2026-09-24). Only a counted run can be or set a best.
  SELECT s.id, s.kid_id, s.on_date, s.started_at, s.seconds, s.limit_seconds, s.burpee_count,
         s.counted, s.prior_best,
         public.family_burpee_points(s.seconds, s.limit_seconds, s.burpee_count, s.prior_best, s.stopped_early)
    FROM (SELECT p.id, p.kid_id, p.on_date, p.started_at, p.seconds, p.limit_seconds, p.burpee_count, p.stopped_early, p.counted,
                 ceil(round(p.best_pace * p.burpee_count, 6))::int AS prior_best
            FROM (SELECT t.id, t.kid_id, (t.started_at AT TIME ZONE 'America/Chicago')::date AS on_date, t.started_at,
                         t.seconds, t.limit_seconds, t.burpee_count, t.stopped_early,
                         public.family_burpee_counts(t.seconds, t.burpee_count) AND NOT t.stopped_early AS counted,
                         min(t.seconds::numeric / NULLIF(t.burpee_count, 0))
                           FILTER (WHERE public.family_burpee_counts(t.seconds, t.burpee_count) AND NOT t.stopped_early)
                           OVER (PARTITION BY t.kid_id ORDER BY t.started_at, t.id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS best_pace
                    FROM public.family_timers t
                   WHERE t.kind = 'burpees' AND t.ended_at IS NOT NULL) p) s
   ORDER BY s.started_at;
$$;

CREATE OR REPLACE FUNCTION public.family_timer_stop(p_kid_id uuid, p_kind text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_row public.family_timers; v_secs int; v_over int; v_fine numeric; v_rate numeric; v_ledger uuid; v_res jsonb;
        v_day date; v_chore uuid; v_counted boolean; v_checked boolean := false; v_check_error text; v_log jsonb;
BEGIN
  PERFORM public.require_login('family');
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
          v_log := public.family_set_status(v_chore, v_day, 'claimed', NULL, p_kid_id, NULL);
          v_checked := true;
          -- Saved so Continue (family_timer_continue) takes back exactly this check-off.
          UPDATE public.family_timers SET checked_log_id = (v_log->>'id')::uuid WHERE id = v_row.id;
        EXCEPTION WHEN raise_exception THEN
          v_check_error := SQLERRM;  -- e.g. "Finish Morning first." The run still counts.
        END;
      END IF;
    END IF;
    v_res := v_res || jsonb_build_object('checked_off', v_checked, 'check_error', v_check_error);
  END IF;
  RETURN v_res;
END $function$;

CREATE OR REPLACE FUNCTION public.family_timer_continuable(p_kid_id uuid, p_kind text)
RETURNS uuid LANGUAGE sql STABLE SET search_path = public AS $$
  -- The one rule for which stopped timer a parent can pick back up (Peter 2026-09-24): the kid's
  -- latest run of that kind, stopped, started today, and still inside its time limit. A newer
  -- run, or one still going, leaves nothing to continue.
  SELECT t.id
    FROM public.family_timers t
   WHERE t.kid_id = p_kid_id AND t.kind = p_kind AND t.ended_at IS NOT NULL
     AND (t.started_at AT TIME ZONE 'America/Chicago')::date = (now() AT TIME ZONE 'America/Chicago')::date
     AND now() < t.started_at + make_interval(secs => t.limit_seconds)
     AND NOT EXISTS (SELECT 1 FROM public.family_timers r
                      WHERE r.kid_id = t.kid_id AND r.kind = t.kind AND r.id <> t.id
                        AND (r.ended_at IS NULL OR r.started_at > t.started_at))
   LIMIT 1;
$$;
REVOKE EXECUTE ON FUNCTION public.family_timer_continuable(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.family_timer_continuable(uuid, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.family_timer_continue(p_kid_id uuid, p_kind text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_row public.family_timers; v_ledger uuid; v_log uuid;
BEGIN
  PERFORM public.require_login('family');
  -- Peter 2026-09-24: a parent picks a timer back up when a kid stopped it by accident. Continue
  -- undoes the stop. The run keeps its start time, so the clock counts as if it was never stopped.
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'Only a parent can continue a timer.'; END IF;
  v_id := public.family_timer_continuable(p_kid_id, p_kind);
  IF v_id IS NULL THEN RAISE EXCEPTION 'There is no stopped timer to continue.'; END IF;
  SELECT * INTO v_row FROM public.family_timers WHERE id = v_id FOR UPDATE;
  v_ledger := v_row.ledger_id;
  v_log := v_row.checked_log_id;
  UPDATE public.family_timers
     SET ended_at = NULL, seconds = NULL, over_seconds = NULL, fine = NULL, ledger_id = NULL, checked_log_id = NULL, stopped_early = false
   WHERE id = v_id
  RETURNING * INTO v_row;
  -- Take back what the stop did, by the ids it saved: a shower fine, and the Burpees set it
  -- checked off (only while that set still says Done the way the stop left it).
  IF v_ledger IS NOT NULL THEN DELETE FROM public.family_ledger WHERE id = v_ledger; END IF;
  IF v_log IS NOT NULL THEN DELETE FROM public.family_chore_log WHERE id = v_log AND status = 'claimed'; END IF;
  RETURN to_jsonb(v_row);
END $$;
REVOKE EXECUTE ON FUNCTION public.family_timer_continue(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.family_timer_continue(uuid, text) TO authenticated, service_role;

DROP FUNCTION IF EXISTS public.family_timer_list(uuid);
CREATE FUNCTION public.family_timer_list(p_kid_id uuid)
RETURNS TABLE(kind text, icon text, minutes integer, shows_from time without time zone, running_id uuid, started_at timestamp with time zone, limit_seconds integer,
              can_start boolean, continue_id uuid, continue_seconds integer, continue_until timestamp with time zone)
LANGUAGE sql STABLE SET search_path = public AS $$
  WITH today AS (SELECT (now() AT TIME ZONE 'America/Chicago')::date AS d),
  -- A stopped run a parent can still pick back up. Parents only; the kids' screen never gets it.
  cont AS (
    SELECT t.kind, t.id, t.seconds, t.started_at + make_interval(secs => t.limit_seconds) AS until
      FROM (VALUES ('burpees'::text), ('shower'::text)) v(kind)
      CROSS JOIN LATERAL (SELECT public.family_timer_continuable(p_kid_id, v.kind) AS id) f
      JOIN public.family_timers t ON t.id = f.id
     WHERE public.family_is_parent()
  ),
  kinds AS (
    SELECT 'burpees'::text AS kind, '💪'::text AS icon, s.burpee_minutes::int AS minutes, NULL::time AS shows_from, 1 AS ord,
           public.family_next_burpee_chore(k.id, today.d) IS NOT NULL AS can_start
      FROM public.family_kids k
      JOIN public.family_settings s ON s.agency_id = k.agency_id
      CROSS JOIN today
     WHERE k.id = p_kid_id AND k.is_active
       AND (public.family_next_burpee_chore(k.id, today.d) IS NOT NULL
            OR EXISTS (SELECT 1 FROM public.family_timers r WHERE r.kid_id = k.id AND r.kind = 'burpees' AND r.ended_at IS NULL)
            OR EXISTS (SELECT 1 FROM cont WHERE cont.kind = 'burpees'))
    UNION ALL
    SELECT 'shower', '🚿', k.shower_minutes::int, time '17:00', 2, true
      FROM public.family_kids k
     WHERE k.id = p_kid_id AND k.is_active AND k.shower_minutes IS NOT NULL
  )
  SELECT x.kind, x.icon, x.minutes, x.shows_from, t.id, t.started_at, t.limit_seconds,
         x.can_start, c.id, c.seconds, c.until
    FROM kinds x
    LEFT JOIN public.family_timers t ON t.kid_id = p_kid_id AND t.kind = x.kind AND t.ended_at IS NULL
    LEFT JOIN cont c ON c.kind = x.kind
   ORDER BY x.ord;
$$;
REVOKE EXECUTE ON FUNCTION public.family_timer_list(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.family_timer_list(uuid) TO authenticated, service_role;

-- Data -------------------------------------------------------------------------------------
DO $$
DECLARE n int;
BEGIN
  UPDATE public.family_chores SET every_weeks = 2, start_week = DATE '2026-09-19'
   WHERE id IN ('5c638e7d-33e0-442e-8409-9b8cea5714bc', 'a1eb1abb-9978-42df-b53a-9399237faf93',
                'befa4692-6a97-4a93-b012-ce929bff78a2', '771310d5-c5d3-411c-9454-d83a3fb86fb0',
                '84a5bdc1-f1dc-4084-9184-ce6608d1900c')
     AND frequency = 'weekly' AND group_label = 'Office';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 5 THEN RAISE EXCEPTION 'Expected the 5 Office chores, matched %.', n; END IF;
  UPDATE public.family_timers SET stopped_early = true
   WHERE id = '0f4ba5e8-dbbe-4a22-89de-ac3b6310612f' AND kind = 'burpees' AND seconds = 128 AND burpee_count = 80;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'Expected Elliott''s 2:08 run, matched %.', n; END IF;
END $$;

-- family_burpee_points changed its arguments: fail if anything but family_burpee_sessions calls it.
DO $$
DECLARE v text;
BEGIN
  SELECT string_agg(p.proname, ', ') INTO v
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prokind = 'f'
     AND p.proname NOT IN ('family_burpee_points', 'family_burpee_sessions')
     AND pg_get_functiondef(p.oid) LIKE '%family_burpee_points(%';
  IF v IS NOT NULL THEN RAISE EXCEPTION 'family_burpee_points still has callers: %', v; END IF;
END $$;
