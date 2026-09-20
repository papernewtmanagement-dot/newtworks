-- Peter 2026-09-19: while spot-checking he wants to leave a note on an entry,
-- and have it read on the CPR change report.
--
-- The note is stored on the entry itself. The change report is built from
-- change_log, and change_log keeps the whole row as it was after each change,
-- so a note written in the same breath as the verify is already inside the
-- change record. Nothing new has to be threaded through the logging trigger —
-- the report just reads the field that is already sitting there.
--
-- production_changes_for_day only wraps for_range and passes the line straight
-- through, so it needs nothing.

ALTER TABLE public.retention_activity_log
  ADD COLUMN IF NOT EXISTS spot_check_note text;

CREATE OR REPLACE FUNCTION public.rp_verify_activity(p_id uuid, p_note text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; n integer; v_note text;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'only an admin can verify entries' USING ERRCODE='42501'; END IF;
  v_note := NULLIF(btrim(COALESCE(p_note, '')), '');
  UPDATE public.retention_activity_log
     SET verified_at = now(), verified_by = a.actor_id, updated_at = now(),
         spot_check_note = COALESCE(v_note, spot_check_note)
   WHERE id = p_id AND agency_id = a.agency_id AND status = 'credited' AND verified_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'nothing to verify: entry not found, already verified, or removed'; END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_id, 'note', v_note);
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_verify_activity(uuid, text) TO authenticated;

-- A note on its own, without verifying, for something he wants on the report
-- but is not ready to call good.
CREATE OR REPLACE FUNCTION public.rp_spot_check_note(p_id uuid, p_note text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; n integer;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'only an admin can leave a spot-check note' USING ERRCODE='42501'; END IF;
  UPDATE public.retention_activity_log
     SET spot_check_note = NULLIF(btrim(COALESCE(p_note, '')), ''), updated_at = now()
   WHERE id = p_id AND agency_id = a.agency_id;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'that entry is not on file any more'; END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_spot_check_note(uuid, text) TO authenticated;

DROP FUNCTION IF EXISTS public.rp_cancel_word_review(date);
DROP FUNCTION IF EXISTS public.rp_spot_check_sample(date, integer);
DROP FUNCTION IF EXISTS public.rp_spot_check_pool(date);

CREATE FUNCTION public.rp_spot_check_pool(p_week_end date)
RETURNS TABLE(id uuid, team_member_id uuid, first_name text, activity_key text, label text,
              occurred_on date, customer_label text, phone_last4 text, note text,
              ecrm_url text, points numeric, spot_check_note text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
  wk AS (SELECT public.rp_week_end(p_week_end) AS week_end)
  SELECT l.id, l.team_member_id, t.first_name, l.activity_key, v.label, l.occurred_on,
         l.customer_label, l.phone_last4,
         CASE WHEN l.review_platform IS NULL THEN l.note
              ELSE initcap(l.review_platform) || COALESCE(' — ' || l.note, '') END,
         l.ecrm_url, l.points, l.spot_check_note
  FROM public.retention_activity_log l
  JOIN me ON me.agency_id = l.agency_id
  LEFT JOIN public.team_directory t ON t.id = l.team_member_id
  LEFT JOIN public.retention_point_values v
    ON v.activity_key = l.activity_key AND v.agency_id = (SELECT agency_id FROM me)
  WHERE public.is_agency_admin() AND l.source = 'manual' AND l.status = 'credited'
    AND l.verified_at IS NULL
    AND l.created_by IS NOT NULL
    AND l.created_by = l.team_member_id
    AND COALESCE(v.spot_checkable, true)
    AND public.rp_week_end(l.occurred_on) = (SELECT week_end FROM wk);
$function$;

REVOKE EXECUTE ON FUNCTION public.rp_spot_check_pool(date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rp_spot_check_pool(date) FROM anon, authenticated;

CREATE FUNCTION public.rp_spot_check_sample(p_week_end date, p_limit integer DEFAULT 10)
RETURNS TABLE(id uuid, team_member_id uuid, first_name text, activity_key text, label text,
              occurred_on date, customer_label text, customer_first_name text,
              customer_last_initial text, phone_last4 text, note text, ecrm_url text,
              points numeric, spot_check_note text, remaining integer, households_left integer)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
  pool AS (SELECT * FROM public.rp_spot_check_pool(p_week_end)),
  risk AS (
    SELECT l.activity_key,
           (count(*) FILTER (WHERE l.status = 'void') + 1)::numeric / (count(*) + 8) AS w
      FROM public.retention_activity_log l
      JOIN me ON me.agency_id = l.agency_id
     WHERE l.source = 'manual'
     GROUP BY l.activity_key
  ),
  hh AS (
    SELECT p.customer_label, COALESCE(p.phone_last4, '') AS ph,
           max(COALESCE(r.w, 1.0 / 9)) AS w
      FROM pool p LEFT JOIN risk r ON r.activity_key = p.activity_key
     GROUP BY 1, 2
  ),
  picked AS (
    SELECT h.customer_label, h.ph FROM hh h
     ORDER BY power(
       ((('x' || substr(md5(COALESCE(h.customer_label, '') || h.ph
                            || public.rp_week_end(p_week_end)::text), 1, 8))::bit(32)::int::numeric
         + 2147483648) / 4294967296.0),
       1.0 / GREATEST(h.w, 0.01)) DESC
     LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 10), 50))
  )
  SELECT p.id, p.team_member_id, p.first_name, p.activity_key, p.label, p.occurred_on,
         p.customer_label, l.customer_first_name, l.customer_last_initial, p.phone_last4,
         p.note, p.ecrm_url, p.points, p.spot_check_note,
         (SELECT count(*) FROM pool)::integer,
         (SELECT count(*) FROM hh)::integer
    FROM pool p
    JOIN picked k ON COALESCE(k.customer_label, '') = COALESCE(p.customer_label, '')
                 AND k.ph = COALESCE(p.phone_last4, '')
    JOIN public.retention_activity_log l ON l.id = p.id
   ORDER BY p.customer_label, p.occurred_on, p.label;
$function$;

GRANT EXECUTE ON FUNCTION public.rp_spot_check_sample(date, integer) TO authenticated;

CREATE FUNCTION public.rp_cancel_word_review(p_week_end date)
RETURNS TABLE(id uuid, team_member_id uuid, first_name text, activity_key text, label text,
              occurred_on date, customer_label text, customer_first_name text,
              customer_last_initial text, phone_last4 text, note text,
              ecrm_url text, points numeric, spot_check_note text, has_cancelation boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
  pool AS (SELECT * FROM public.rp_spot_check_pool(p_week_end))
  SELECT p.id, p.team_member_id, p.first_name, p.activity_key, p.label, p.occurred_on,
         p.customer_label, l.customer_first_name, l.customer_last_initial, p.phone_last4,
         p.note, p.ecrm_url, p.points, p.spot_check_note,
         EXISTS (
           SELECT 1 FROM public.cancelation_log c
            WHERE c.agency_id = (SELECT agency_id FROM me) AND c.status = 'active'
              AND lower(btrim(COALESCE(c.customer_label,''))) = lower(btrim(COALESCE(p.customer_label,'')))
              AND (p.phone_last4 IS NULL OR c.phone_last4 IS NULL OR c.phone_last4 = p.phone_last4)
              AND c.canceled_on BETWEEN p.occurred_on - 21 AND p.occurred_on + 21
         )
  FROM pool p
  JOIN public.retention_activity_log l ON l.id = p.id
  WHERE p.activity_key <> 'cancelation_saved' AND COALESCE(p.note,'') ~* '\mcancel'
  ORDER BY p.occurred_on DESC, p.first_name;
$function$;

GRANT EXECUTE ON FUNCTION public.rp_cancel_word_review(date) TO authenticated;

-- The change report carries the spot-check note on the line.
DO $do$
DECLARE d text; old text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO d FROM pg_proc
   WHERE pronamespace = 'public'::regnamespace AND proname = 'production_changes_for_range';
  IF position('spot_check_note' in d) > 0 THEN RETURN; END IF;

  old := 'r.what, r.item, r.subject, r.changed_fields';
  IF position(old in d) = 0 THEN
    RAISE EXCEPTION 'production_changes_for_range does not look the way this migration expects';
  END IF;
  d := replace(d, old, old || ', NULLIF(btrim(COALESCE(r.new_row->>''spot_check_note'', '''')), '''') AS spot_note');

  old := 'CASE WHEN g.row_count > 1 THEN '' ['' || g.row_count || '' records]'' ELSE '''' END) AS line';
  IF position(old in d) = 0 THEN
    RAISE EXCEPTION 'the production_changes line builder does not look the way this migration expects';
  END IF;
  EXECUTE replace(d, old,
    'CASE WHEN g.row_count > 1 THEN '' ['' || g.row_count || '' records]'' ELSE '''' END ||
          COALESCE('' — spot-check: '' || g.spot_note, '''')) AS line');
END $do$;
