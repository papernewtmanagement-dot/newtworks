-- Appointments join Marketing Points on the Scoreboard. Kept pays $5 flat,
-- Sold pays $10 plus $0.10 for each one already sold this quarter, and both
-- pay the person who ESCALATED the appointment, never the seller
-- (Peter 2026-09-11). Patched in place so the rest of the function is
-- untouched.
DO $do$
DECLARE d text; n int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d
    FROM pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
   WHERE n2.nspname = 'public' AND p.proname = 'rp_week_scoreboard_for';

  IF position($anchor$m_ev AS (SELECT * FROM m_rev UNION ALL SELECT * FROM m_rq UNION ALL SELECT * FROM m_rs),$anchor$ IN d) = 0 THEN
    RAISE EXCEPTION 'marketing union anchor not found — do not patch blind';
  END IF;

  d := replace(d,
    $anchor$m_ev AS (SELECT * FROM m_rev UNION ALL SELECT * FROM m_rq UNION ALL SELECT * FROM m_rs),$anchor$,
    $new$m_ak AS (
    SELECT ap.team_member_id AS tm, 'appointment_kept'::text AS event_key, ap.kept_on AS on_date, ap.customer_label AS customer, ap.id, 0::int AS prior
    FROM public.appointment_log ap
    WHERE ap.agency_id = p_agency_id AND ap.status = 'active'
      AND ap.escalated_to_team_member_id IS NOT NULL
      AND ap.escalated_to_team_member_id <> ap.team_member_id
      AND ap.kept_on IS NOT NULL AND public.rp_week_end(ap.kept_on) = v_week_end
  ),
  m_as AS (
    SELECT ap.team_member_id AS tm, 'appointment_sold'::text AS event_key, ap.sold_on AS on_date, ap.customer_label AS customer, ap.id,
      (SELECT count(*) FROM public.appointment_log q
        WHERE q.agency_id = p_agency_id AND q.status = 'active' AND q.team_member_id = ap.team_member_id
          AND q.escalated_to_team_member_id IS NOT NULL AND q.escalated_to_team_member_id <> q.team_member_id
          AND q.sold_on IS NOT NULL AND q.sold_on >= v_cycle_start
          AND (q.sold_on < ap.sold_on OR (q.sold_on = ap.sold_on AND q.created_at < ap.created_at)))::int AS prior
    FROM public.appointment_log ap
    WHERE ap.agency_id = p_agency_id AND ap.status = 'active'
      AND ap.escalated_to_team_member_id IS NOT NULL
      AND ap.escalated_to_team_member_id <> ap.team_member_id
      AND ap.sold_on IS NOT NULL AND public.rp_week_end(ap.sold_on) = v_week_end
  ),
  m_ev AS (SELECT * FROM m_rev UNION ALL SELECT * FROM m_rq UNION ALL SELECT * FROM m_rs UNION ALL SELECT * FROM m_ak UNION ALL SELECT * FROM m_as),$new$);

  d := replace(d,
    $anchor$           OR (l.activity_key = 'google_review' AND l.occurred_on BETWEEN v_cycle_start AND v_week_end))
  ),$anchor$,
    $new$           OR (l.activity_key = 'google_review' AND l.occurred_on BETWEEN v_cycle_start AND v_week_end))
    UNION
    SELECT ap.team_member_id FROM public.appointment_log ap
    WHERE ap.agency_id = p_agency_id AND ap.status = 'active'
      AND (public.rp_week_end(ap.kept_on) = v_week_end OR public.rp_week_end(ap.sold_on) = v_week_end)
  ),$new$);

  EXECUTE d;
END $do$;
