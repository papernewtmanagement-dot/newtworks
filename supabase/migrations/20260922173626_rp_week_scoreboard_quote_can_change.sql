-- Peter 2026-09-22 lockdown: the week board's quote list says whether each quote
-- can still be removed, from the same rule the server enforces.
DO $patch$
DECLARE d text; n text;
BEGIN
  d := pg_get_functiondef('public.rp_week_scoreboard_for(uuid,date)'::regprocedure);
  n := replace(d, $q$SELECT q.team_member_id AS tm, q.id, q.quote_date,$q$, $q$SELECT q.team_member_id AS tm, q.id, q.created_at, q.quote_date,$q$);
  IF n = d OR length(n) - length(d) <> length(' q.created_at,') THEN RAISE EXCEPTION 'rp_week_scoreboard_for patch 1 missed'; END IF; d := n;
  n := replace(d, $q$'dup', dup, 'phone', phone_last4)$q$, $q$'dup', dup, 'phone', phone_last4,
                                        'can_change', public.rp_entry_can_change(tm, created_at))$q$);
  IF n = d THEN RAISE EXCEPTION 'rp_week_scoreboard_for patch 2 missed'; END IF;
  EXECUTE n;
END $patch$;
