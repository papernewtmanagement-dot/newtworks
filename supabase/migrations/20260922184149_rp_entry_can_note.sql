-- Peter 2026-09-22 lockdown, follow-up. Who may add a note is one server rule,
-- read by every screen, instead of being worked out again in the browser.
-- Also: the rule functions never answer "unknown". A signed-in person with no
-- team row gets a plain no, whatever calls them.

CREATE OR REPLACE FUNCTION public.rp_entry_can_change(p_owner uuid, p_created_at timestamptz)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.is_agency_admin()
      OR COALESCE(p_owner = public.rp_my_team_id() AND public.rp_entered_today(p_created_at), false);
$function$;

CREATE OR REPLACE FUNCTION public.rp_sale_can_edit(p_owner uuid, p_created_at timestamptz, p_sale_id uuid)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.rp_entry_can_change(p_owner, p_created_at)
      OR COALESCE(p_owner = public.rp_my_team_id()
                  AND EXISTS (SELECT 1 FROM public.sales_log_products p WHERE p.sales_log_id = p_sale_id AND p.issued_date IS NULL), false);
$function$;

CREATE OR REPLACE FUNCTION public.rp_appt_can_mark(p_host uuid)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.is_agency_admin() OR COALESCE(p_host = public.rp_my_team_id(), false);
$function$;

CREATE OR REPLACE FUNCTION public.rp_autopay_can_change(p_owner uuid, p_created_at timestamptz, p_on_now boolean)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.rp_entry_can_change(p_owner, p_created_at)
      OR COALESCE(NOT COALESCE(p_on_now, false) AND p_owner = public.rp_my_team_id(), false);
$function$;

-- Add a note: owner/manager, the person the record belongs to, or an appointment's host.
CREATE OR REPLACE FUNCTION public.rp_entry_can_note(p_owner uuid, p_host uuid DEFAULT NULL)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.is_agency_admin()
      OR COALESCE((SELECT m = p_owner OR m = p_host FROM (SELECT public.rp_my_team_id() AS m) x), false);
$function$;

CREATE OR REPLACE FUNCTION public.rp_sale_can_note(r public.sales_log)
 RETURNS boolean LANGUAGE sql STABLE AS $function$ SELECT public.rp_entry_can_note(r.team_member_id, NULL); $function$;
CREATE OR REPLACE FUNCTION public.rp_appt_can_note(r public.appointment_log)
 RETURNS boolean LANGUAGE sql STABLE AS $function$ SELECT public.rp_entry_can_note(r.team_member_id, r.escalated_to_team_member_id); $function$;
CREATE OR REPLACE FUNCTION public.rp_act_can_note(r public.retention_activity_now)
 RETURNS boolean LANGUAGE sql STABLE AS $function$ SELECT public.rp_entry_can_note(r.team_member_id, NULL); $function$;

DO $patch$
DECLARE d text; n text;
BEGIN
  -- rp_add_note checks with the same rule.
  d := pg_get_functiondef('public.rp_add_note(text,uuid,text)'::regprocedure);
  n := replace(d, $q$IF NOT a.is_admin AND a.actor_id IS DISTINCT FROM v_owner AND a.actor_id IS DISTINCT FROM v_host THEN$q$,
                  $q$IF NOT public.rp_entry_can_note(v_owner, v_host) THEN$q$);
  IF n = d THEN RAISE EXCEPTION 'rp_add_note patch missed'; END IF;
  EXECUTE n;

  -- History list: one more column saying whether a note can be added.
  d := pg_get_functiondef('public.rp_recent_entries(integer,uuid,integer,text,date,date,text)'::regprocedure);
  n := replace(d, $q$entry_source text, can_change boolean)$q$, $q$entry_source text, can_change boolean, can_note boolean)$q$);
  IF n = d THEN RAISE EXCEPTION 'rp_recent_entries patch 1 missed'; END IF; d := n;
  n := replace(d, $q$public.rp_entry_can_change(r.team_member_id, r.created_at) AS can_change$q$,
                  $q$public.rp_entry_can_change(r.team_member_id, r.created_at) AS can_change,
         public.rp_entry_can_note(r.team_member_id, CASE WHEN r.kind = 'appointment'
           THEN (SELECT x.escalated_to_team_member_id FROM public.appointment_log x WHERE x.id = r.id) END) AS can_note$q$);
  IF n = d THEN RAISE EXCEPTION 'rp_recent_entries patch 2 missed'; END IF;
  DROP FUNCTION public.rp_recent_entries(integer,uuid,integer,text,date,date,text);
  EXECUTE n;
  GRANT EXECUTE ON FUNCTION public.rp_recent_entries(integer,uuid,integer,text,date,date,text) TO authenticated, service_role;

  -- Customer account timeline: same flag.
  d := pg_get_functiondef('public.rp_customer_account(text,text)'::regprocedure);
  n := replace(d, $q$public.rp_entry_can_change(e.team_member_id, e.created_at) AS can_change$q$,
                  $q$public.rp_entry_can_change(e.team_member_id, e.created_at) AS can_change,
           public.rp_entry_can_note(e.team_member_id, CASE WHEN e.kind = 'appointment'
             THEN (SELECT x.escalated_to_team_member_id FROM public.appointment_log x WHERE x.id = e.id) END) AS can_note$q$);
  IF n = d THEN RAISE EXCEPTION 'rp_customer_account patch missed'; END IF;
  EXECUTE n;
END $patch$;

NOTIFY pgrst, 'reload schema';
