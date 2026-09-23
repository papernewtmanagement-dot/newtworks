-- Peter 2026-09-22: money that posts right away (extra chores, bonuses) walks the kid through the
-- tithe and investment math right away, the same steps as the week close-out. Each income row remembers
-- that its math is done, so the close-out does not ask for it twice.
ALTER TABLE public.family_chore_log ADD COLUMN IF NOT EXISTS math_done_at timestamptz;
ALTER TABLE public.family_ledger ADD COLUMN IF NOT EXISTS math_done_at timestamptz;

DROP FUNCTION IF EXISTS public.family_week_events(uuid, date);
CREATE FUNCTION public.family_week_events(p_kid_id uuid, p_week_start date)
 RETURNS TABLE(seq integer, event_date date, kind text, label text, bucket text, amount numeric, is_income boolean, tithe numeric, invest numeric, ref_id uuid, math_done boolean)
 LANGUAGE sql
 STABLE
AS $function$
  WITH k AS (SELECT tithe_pct, invest_pct FROM public.family_kids WHERE id = p_kid_id),
  logs AS (
    SELECT l.id, l.occurrence_date AS d, l.amount, l.math_done_at, c.frequency, c.title
    FROM public.family_chore_log l JOIN public.family_chores c ON c.id = l.chore_id
    WHERE l.kid_id = p_kid_id AND l.occurrence_date BETWEEN p_week_start AND p_week_start + 6
  ),
  ev AS (
    SELECT d AS event_date, 1 AS ord, 'fines' AS kind,
           trim(to_char(d, 'Day')) || ': ' || count(*) || CASE WHEN count(*) = 1 THEN ' fine' ELSE ' fines' END AS label,
           'spend' AS bucket, sum(amount) AS amount, false AS is_income, NULL::uuid AS ref_id, false AS math_done
    FROM logs WHERE amount < 0 GROUP BY d
    UNION ALL
    SELECT d, 2, 'extra', title, 'spend', amount, true, id, math_done_at IS NOT NULL FROM logs WHERE frequency = 'extra' AND amount > 0
    UNION ALL
    SELECT entry_date, 3, kind,
           CASE kind WHEN 'payout' THEN 'Cash paid out' WHEN 'bonus' THEN 'Bonus' WHEN 'adjustment' THEN 'Adjustment'
                     WHEN 'tithe_given' THEN 'Tithe given' WHEN 'invested' THEN 'Invested' WHEN 'fine' THEN 'Fine' ELSE kind END
             || COALESCE(' · ' || note, ''),
           bucket, amount, (kind = 'bonus'), id, math_done_at IS NOT NULL
    FROM public.family_ledger
    WHERE kid_id = p_kid_id AND kind <> 'opening_balance' AND entry_date BETWEEN p_week_start AND p_week_start + 6
    UNION ALL
    SELECT p_week_start + 6, 4, 'chore_pay', 'Chores this week', 'spend', sum(amount), true, NULL::uuid, false
    FROM logs WHERE frequency <> 'extra' AND amount > 0 HAVING sum(amount) > 0
  )
  SELECT (row_number() OVER (ORDER BY ev.event_date, ev.ord, ev.label))::int, ev.event_date, ev.kind, ev.label,
         ev.bucket, ev.amount, ev.is_income,
         CASE WHEN ev.is_income THEN public.family_set_aside(ev.amount, k.tithe_pct) ELSE 0 END,
         CASE WHEN ev.is_income THEN public.family_set_aside(ev.amount, k.invest_pct) ELSE 0 END,
         ev.ref_id, ev.math_done
  FROM ev CROSS JOIN k
  ORDER BY 1;
$function$;
GRANT EXECUTE ON FUNCTION public.family_week_events(uuid, date) TO authenticated, service_role;

-- Money math still to do for one kid: every extra or bonus whose math is not done, oldest first,
-- with the balances as they stood before those events (so the steps land on today's balances).
CREATE OR REPLACE FUNCTION public.family_math_todo(p_kid_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
  WITH t AS (SELECT public.family_week_start((now() AT TIME ZONE 'America/Chicago')::date) AS ws),
  k AS (SELECT id, tithe_pct, invest_pct, tracking_start FROM public.family_kids WHERE id = p_kid_id),
  pend AS (
    SELECT e.* FROM k, t,
    generate_series(public.family_week_start(k.tracking_start), t.ws, interval '7 days') w
    CROSS JOIN LATERAL public.family_week_events(p_kid_id, w::date) e
    WHERE e.kind IN ('extra', 'bonus') AND e.is_income AND NOT e.math_done
  ),
  now_bal AS (SELECT m.* FROM t, public.family_kid_money(p_kid_id, t.ws) m)
  SELECT jsonb_build_object(
    'kid_id', k.id, 'tithe_pct', k.tithe_pct, 'invest_pct', k.invest_pct,
    'start', jsonb_build_object(
      'spend',  (SELECT spend  FROM now_bal) - COALESCE((SELECT sum(amount - tithe - invest) FROM pend), 0),
      'tithe',  (SELECT tithe  FROM now_bal) - COALESCE((SELECT sum(tithe) FROM pend), 0),
      'invest', (SELECT invest FROM now_bal) - COALESCE((SELECT sum(invest) FROM pend), 0)),
    'events', COALESCE((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.event_date, p.seq) FROM pend p), '[]'::jsonb))
  FROM k;
$function$;
GRANT EXECUTE ON FUNCTION public.family_math_todo(uuid) TO authenticated, service_role;

-- Marks the math done on the given income rows. Only touches math_done_at.
CREATE OR REPLACE FUNCTION public.family_math_done(p_ref_ids uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE n int := 0; m int;
BEGIN
  IF NOT (public.family_is_parent() OR public.auth_is_family()) THEN RAISE EXCEPTION 'Not allowed.'; END IF;
  UPDATE public.family_chore_log SET math_done_at = now()
   WHERE id = ANY(p_ref_ids) AND math_done_at IS NULL AND agency_id = '126794dd-25ff-47d2-a436-724499733365';
  GET DIAGNOSTICS m = ROW_COUNT; n := n + m;
  UPDATE public.family_ledger SET math_done_at = now()
   WHERE id = ANY(p_ref_ids) AND math_done_at IS NULL AND kind = 'bonus' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';
  GET DIAGNOSTICS m = ROW_COUNT; n := n + m;
  RETURN n;
END $function$;
REVOKE ALL ON FUNCTION public.family_math_done(uuid[]) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.family_math_done(uuid[]) TO authenticated, service_role;
