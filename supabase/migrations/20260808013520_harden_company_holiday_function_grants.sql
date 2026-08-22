-- Security advisor caught these immediately after the holidays build: Postgres
-- grants EXECUTE to PUBLIC on new functions by default, so all three SECURITY
-- DEFINER writers were reachable by the anon role over /rest/v1/rpc/. An
-- unauthenticated caller could have seeded holidays or created approved paid
-- time-off rows. Nothing in the frontend calls these — they run from
-- run_internal_recipe(), which is itself SECURITY DEFINER and executes as the
-- owner — so no role needs EXECUTE at all.

REVOKE EXECUTE ON FUNCTION public.seed_company_holidays(uuid, int) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.seed_company_holidays_runner(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.materialize_holiday_time_off_for_account_associates(uuid, date) FROM PUBLIC, anon, authenticated;

-- Pure date arithmetic, no table access, no SECURITY DEFINER. Harmless to expose,
-- but pin the search_path so it cannot be influenced by a caller's setting.
CREATE OR REPLACE FUNCTION public.nth_weekday_of_month(
  p_year int, p_month int, p_isodow int, p_nth int
) RETURNS date
LANGUAGE sql IMMUTABLE SET search_path TO 'pg_catalog', 'public' AS $function$
  -- p_isodow: Monday=1 .. Sunday=7. p_nth: 1-based, or -1 for the last one.
  SELECT CASE
    WHEN p_nth > 0 THEN
      make_date(p_year, p_month, 1)
        + ((p_isodow - EXTRACT(isodow FROM make_date(p_year, p_month, 1))::int + 7) % 7)
        + (7 * (p_nth - 1))
    ELSE
      (make_date(p_year, p_month, 1) + INTERVAL '1 month - 1 day')::date
        - ((EXTRACT(isodow FROM (make_date(p_year, p_month, 1) + INTERVAL '1 month - 1 day')::date)::int
            - p_isodow + 7) % 7)
  END;
$function$;
