-- Handbook "Your Path": Unit Manager (3-5 people) < Section Manager (3-5 units)
-- < Office Manager (3-5 sections). role_level_rank was missing Section Manager
-- and Office Manager entirely (both fell to ELSE 9, sorting below Account
-- Associate). Three functions also carried their own inline copy of the
-- manager-tier list, so promoting anyone to Section Manager silently dropped
-- them out of Win the Week targets, personal quote minimums, and the 4-day perk.

-- Canonical manager-tier list. Owner excluded on purpose (each caller gates it).
CREATE OR REPLACE FUNCTION public.manager_tier_levels()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT ARRAY['Account Manager','Unit Manager','Section Manager','Office Manager']::text[];
$function$;

CREATE OR REPLACE FUNCTION public.role_level_rank(p_role_level text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_role_level
    WHEN 'Owner'             THEN 1
    WHEN 'Office Manager'    THEN 2
    WHEN 'Section Manager'   THEN 3
    WHEN 'Unit Manager'      THEN 4
    WHEN 'Account Manager'   THEN 5
    WHEN 'Account Associate' THEN 6
    WHEN 'Aspirant'          THEN 7
    ELSE 9 END;
$function$;

DO $mig$
DECLARE d text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO d FROM pg_proc
   WHERE pronamespace='public'::regnamespace AND proname='get_expected_teammates';
  d := replace(d, $o$r.role_level IN ('Account Manager', 'Unit Manager')$o$,
                  $n$r.role_level = ANY(public.manager_tier_levels())$n$);
  IF position($o$'Account Manager', 'Unit Manager'$o$ in d) > 0 THEN
    RAISE EXCEPTION 'get_expected_teammates: inline manager-tier list left behind';
  END IF;
  EXECUTE d;

  SELECT pg_get_functiondef(oid) INTO d FROM pg_proc
   WHERE pronamespace='public'::regnamespace AND proname='get_weekly_cpr_requirements';
  d := replace(d, $o$t.role_level IN ('Account Manager','Unit Manager')$o$,
                  $n$t.role_level = ANY(public.manager_tier_levels())$n$);
  IF position($o$'Account Manager','Unit Manager'$o$ in d) > 0 THEN
    RAISE EXCEPTION 'get_weekly_cpr_requirements: inline manager-tier list left behind';
  END IF;
  EXECUTE d;

  SELECT pg_get_functiondef(oid) INTO d FROM pg_proc
   WHERE pronamespace='public'::regnamespace AND proname='materialize_standing_time_off'
     AND pg_get_function_identity_arguments(oid)='p_agency_id uuid, p_week_start date, p_force boolean';
  d := replace(d, $o$v_role_level NOT IN ('Account Manager','Unit Manager')$o$,
                  $n$NOT (v_role_level = ANY(public.manager_tier_levels()))$n$);
  d := replace(d, $o$Only Account Managers and Unit Managers qualify$o$,
                  $n$Only manager-tier levels (public.manager_tier_levels()) qualify$n$);
  IF position($o$'Account Manager','Unit Manager'$o$ in d) > 0 THEN
    RAISE EXCEPTION 'materialize_standing_time_off: inline manager-tier list left behind';
  END IF;
  EXECUTE d;
END $mig$;
