-- Peter's live test 2026-10-04 (ending Rodney again, with his real 9/25 end
-- date) turned up two faults in the termination flow.
--
-- 1. Telegram. telegram_group_remove_member rightly skipped, because his 9/25
--    departure was already handled, but terminate-team-member only accepted a
--    removal made in the last ten minutes. It reported "no Telegram group
--    removal was recorded" and opened a false task. "This departure is already
--    handled" is now one rule, telegram_departure_removal(), read by both.
--
-- 2. Notes. The site still wrote termination and reactivation notes to
--    team_behavioral_notes, which was folded into team_profile.behavioral_log
--    and dropped on 2026-07-16, so none has saved since. team_log_append() is
--    now the one way to add an entry to that log.

CREATE OR REPLACE FUNCTION public.telegram_departure_removal(p_team_id uuid)
 RETURNS SETOF public.telegram_group_removals
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- The removal that covers this person's current departure: a real (not
  -- dry-run) team-group removal at or after the moment they left, the earlier
  -- of archived_at and end_date. A removal from an earlier stint does not
  -- count, so someone reactivated and terminated again is removed again.
  SELECT r.*
  FROM public.team t
  JOIN public.telegram_group_removals r
    ON r.team_id = t.id AND r.route_key = 'team'
  WHERE t.id = p_team_id
    AND r.removed_at >= coalesce(least(t.archived_at, t.end_date::timestamptz), '-infinity'::timestamptz)
    AND NOT coalesce((r.api_result->>'dry_run')::boolean, false)
  ORDER BY r.removed_at DESC
  LIMIT 1;
$function$;

REVOKE ALL ON FUNCTION public.telegram_departure_removal(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.telegram_departure_removal(uuid) TO service_role;

-- telegram_group_remove_member skips through the same rule. Patched in place,
-- so nothing else in it changes; each piece must be found exactly once.
DO $do$
DECLARE
  v_def  text := pg_get_functiondef('public.telegram_group_remove_member(uuid,text)'::regprocedure);
  v_old  text := $o$  v_left := least(v_t.archived_at, v_t.end_date::timestamptz);

  IF EXISTS (SELECT 1 FROM public.telegram_group_removals r
              WHERE r.team_id = p_team_id AND r.route_key = 'team'
                AND r.removed_at >= coalesce(v_left, '-infinity'::timestamptz)
                AND NOT coalesce((r.api_result->>'dry_run')::boolean, false)) THEN$o$;
  v_new  text := $n$  -- "This departure is already handled" is one rule, kept in
  -- telegram_departure_removal(); terminate-team-member reads it too.
  IF EXISTS (SELECT 1 FROM public.telegram_departure_removal(p_team_id)) THEN$n$;
  v_decl text := $d$  v_left   timestamptz;
$d$;
BEGIN
  IF array_length(string_to_array(v_def, v_old), 1) <> 2 THEN
    RAISE EXCEPTION 'telegram_group_remove_member: skip check not found exactly once';
  END IF;
  IF array_length(string_to_array(v_def, v_decl), 1) <> 2 THEN
    RAISE EXCEPTION 'telegram_group_remove_member: v_left declaration not found exactly once';
  END IF;
  EXECUTE replace(replace(v_def, v_old, v_new), v_decl, '');
END
$do$;

-- One way to add a dated entry to a team member's notes log
-- (team_profile.behavioral_log), newest first, in the format the 2026-07-16
-- fold used: "## <date> · <kind>[ · source: <source>]", then the text, with
-- entries split by a --- line. Makes their profile row when there is none.
-- Runs as the caller, so team_profile's own rules keep it to admins.
CREATE OR REPLACE FUNCTION public.team_log_append(p_team_id uuid, p_date date, p_kind text, p_text text, p_source text DEFAULT NULL)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_entry text := format(E'## %s · %s%s\n%s',
                    COALESCE(p_date, (now() AT TIME ZONE 'America/Chicago')::date)::text,
                    COALESCE(NULLIF(btrim(p_kind), ''), 'observation'),
                    CASE WHEN NULLIF(btrim(p_source), '') IS NOT NULL THEN ' · source: ' || btrim(p_source) ELSE '' END,
                    COALESCE(NULLIF(btrim(p_text), ''), '(no text)'));
BEGIN
  INSERT INTO public.team_profile AS tp (agency_id, team_member_id, behavioral_log)
  SELECT t.agency_id, t.id, v_entry
  FROM public.team t
  WHERE t.id = p_team_id
  ON CONFLICT (team_member_id) DO UPDATE
    SET behavioral_log = v_entry || COALESCE(E'\n\n---\n\n' || NULLIF(tp.behavioral_log, ''), ''),
        updated_at = now();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Team member not found';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.team_log_append(uuid, date, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.team_log_append(uuid, date, text, text, text) TO authenticated, service_role;

