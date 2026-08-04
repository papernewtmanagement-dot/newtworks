-- ═════════════════════════════════════════════════════════════════════════════
-- Authorisation guards on the six functions signed-in staff can still reach.
-- Scope set by Peter, 2026-08-04:
--   pfa_close_day                 stays open to any signed-in teammate  (no change)
--   pfa_void_deposit              stays open to any signed-in teammate  (no change)
--   pfa_recompute_reconciliation  owner / manager only
--   pfa_resend_close_telegram     owner / manager only
--   recompute_cpr_outcome         owner / manager only
--   deny_time_clock_edit          owner / manager only
--   cancel_time_clock_edit        the person who raised the request, or owner/manager
--   send_mvp_prize_win_telegram   stays open — the prize wheel is operated by the
--                                 team member themselves (MVPBanner / keepSelected in
--                                 CPRDetail.jsx), so the winner fires this when they
--                                 keep their prize. Scoped to the person named in the
--                                 draw so a teammate cannot announce someone else's.
--
-- Everyone signed in shares one database role, so these cannot be enforced by
-- privileges — an admin is the same role as a teammate. The test has to live
-- inside each function body.
--
-- The guard is spliced into the live definition read back from the catalogue
-- rather than the bodies being retyped. Nothing but the inserted block changes,
-- and a function whose body does not match the expected shape aborts the whole
-- migration instead of being silently skipped.
-- ═════════════════════════════════════════════════════════════════════════════

DO $outer$
DECLARE
  r record;
  v_def text;
  v_body_start int;
  v_pos int;
  v_count int := 0;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public.pfa_recompute_reconciliation(uuid)',
$g$  IF coalesce(auth.role(), '') <> 'service_role' AND NOT public.is_agency_admin() THEN
    RAISE EXCEPTION 'not authorized: recomputing a reconciliation is owner or manager only';
  END IF;
$g$),
      ('public.pfa_resend_close_telegram(uuid)',
$g$  IF coalesce(auth.role(), '') <> 'service_role' AND NOT public.is_agency_admin() THEN
    RAISE EXCEPTION 'not authorized: resending a daily close is owner or manager only';
  END IF;
$g$),
      ('public.recompute_cpr_outcome(uuid,date)',
$g$  IF coalesce(auth.role(), '') <> 'service_role' AND NOT public.is_agency_admin() THEN
    RAISE EXCEPTION 'not authorized: recomputing the weekly outcome is owner or manager only';
  END IF;
$g$),
      ('public.deny_time_clock_edit(uuid,uuid,text)',
$g$  IF coalesce(auth.role(), '') <> 'service_role' AND NOT public.is_agency_admin() THEN
    RAISE EXCEPTION 'not authorized: denying a time-clock edit is owner or manager only';
  END IF;
$g$),
      ('public.cancel_time_clock_edit(uuid)',
$g$  IF coalesce(auth.role(), '') <> 'service_role'
     AND NOT public.is_agency_admin()
     AND NOT EXISTS (
       SELECT 1 FROM public.time_clock_edit_requests r
       WHERE r.id = p_request_id
         AND r.team_member_id = public.current_team_member_id()
     ) THEN
    RAISE EXCEPTION 'not authorized: only the person who raised this request can cancel it';
  END IF;
$g$),
      ('public.send_mvp_prize_win_telegram(uuid,uuid,uuid)',
$g$  IF coalesce(auth.role(), '') <> 'service_role'
     AND NOT public.is_agency_admin()
     AND p_mvp_team_id IS DISTINCT FROM public.current_team_member_id() THEN
    RAISE EXCEPTION 'not authorized: only the named winner can announce this prize';
  END IF;
$g$)
    ) AS t(sig, guard)
  LOOP
    v_def := pg_get_functiondef(r.sig::regprocedure);

    v_body_start := strpos(v_def, 'AS $function$');
    IF v_body_start = 0 THEN
      RAISE EXCEPTION 'unexpected body delimiter on %, refusing to splice', r.sig;
    END IF;

    IF v_def ~ 'is_agency_admin' THEN
      RAISE EXCEPTION 'already guarded, refusing to double-splice: %', r.sig;
    END IF;

    v_pos := strpos(substr(v_def, v_body_start), E'\nBEGIN\n');
    IF v_pos = 0 THEN
      RAISE EXCEPTION 'no body BEGIN found on %, refusing to splice', r.sig;
    END IF;
    v_pos := v_body_start + v_pos - 1 + length(E'\nBEGIN\n');

    v_def := substr(v_def, 1, v_pos - 1) || r.guard || substr(v_def, v_pos);
    EXECUTE v_def;
    v_count := v_count + 1;
  END LOOP;

  IF v_count <> 6 THEN
    RAISE EXCEPTION 'expected to guard 6 functions, guarded %', v_count;
  END IF;
END $outer$;
