-- Removing a record has always been a void, not a delete, but nothing in the app
-- could bring one back. These three close that: list what has been removed,
-- put one back, and move a record to a different owner.

-- What has been removed lately, across every kind. Admin sees the whole team;
-- everyone else sees their own.
CREATE OR REPLACE FUNCTION public.rp_list_removed(p_days integer DEFAULT 45)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; v_since timestamptz; v_rows jsonb;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  v_since := now() - (GREATEST(COALESCE(p_days, 45), 1) || ' days')::interval;

  SELECT COALESCE(jsonb_agg(x ORDER BY x.voided_at DESC), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT 'sale'::text AS kind, s.id, s.team_member_id, s.customer_label,
           s.submitted_date AS on_date, s.week_end_date, s.voided_at, s.voided_by, s.void_reason,
           COALESCE(s.total_premium, 0)::text AS detail
      FROM public.sales_log s
     WHERE s.agency_id = a.agency_id AND s.status = 'void' AND s.voided_at >= v_since
    UNION ALL
    SELECT 'quote', q.id, q.team_member_id, q.customer_label,
           q.quote_date, q.week_end_date, q.voided_at, q.voided_by, q.void_reason,
           array_to_string(q.products_discussed, ', ')
      FROM public.quote_log q
     WHERE q.agency_id = a.agency_id AND q.status = 'void' AND q.voided_at >= v_since
    UNION ALL
    SELECT 'activity', r.id, r.team_member_id, r.customer_label,
           r.occurred_on, r.week_end_date, r.voided_at, r.voided_by, r.void_reason,
           r.activity_key
      FROM public.retention_activity_log r
     WHERE r.agency_id = a.agency_id AND r.status = 'void' AND r.voided_at >= v_since
       AND r.source = 'manual'
    UNION ALL
    SELECT 'appointment', ap.id, ap.team_member_id, ap.customer_label,
           ap.set_on, ap.week_end_date, ap.voided_at, ap.voided_by, ap.void_reason, NULL
      FROM public.appointment_log ap
     WHERE ap.agency_id = a.agency_id AND ap.status = 'void' AND ap.voided_at >= v_since
    UNION ALL
    SELECT 'cancelation', c.id, c.team_member_id, c.customer_label,
           c.canceled_on, public.rp_week_end(c.canceled_on), c.voided_at, c.voided_by, c.void_reason,
           c.policy_line
      FROM public.cancelation_log c
     WHERE c.agency_id = a.agency_id AND c.status = 'void' AND c.voided_at >= v_since
  ) x
  WHERE a.is_admin OR x.team_member_id = a.actor_id;

  RETURN jsonb_build_object('ok', true, 'rows', v_rows);
END $function$;

-- Put a removed record back exactly as it was. Every branch is the matching
-- rp_void_* run backwards, side effects included.
CREATE OR REPLACE FUNCTION public.rp_restore_record(p_kind text, p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; v_kind text := lower(btrim(COALESCE(p_kind, '')));
BEGIN
  IF v_kind = 'sale' THEN
    SELECT * INTO r FROM public.sales_log WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
    IF r.status <> 'void' THEN RETURN jsonb_build_object('ok', true, 'already_active', true); END IF;
    SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
    IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
    UPDATE public.sales_log
       SET status='active', voided_at=NULL, voided_by=NULL, void_reason=NULL, updated_at=now()
     WHERE id = p_id;
    -- the points the sale earned come back with it
    UPDATE public.retention_activity_log
       SET status='credited', voided_at=NULL, voided_by=NULL, void_reason=NULL, updated_at=now()
     WHERE source='sales_log' AND source_id=p_id AND status='void' AND void_reason='sale entry removed';
    RETURN jsonb_build_object('ok', true, 'id', p_id);
  END IF;

  IF v_kind = 'quote' THEN
    SELECT * INTO r FROM public.quote_log WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
    IF r.status <> 'void' THEN RETURN jsonb_build_object('ok', true, 'already_active', true); END IF;
    SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
    IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
    UPDATE public.quote_log
       SET status='active', voided_at=NULL, voided_by=NULL, void_reason=NULL, updated_at=now()
     WHERE id = p_id;
    RETURN jsonb_build_object('ok', true, 'id', p_id);
  END IF;

  IF v_kind = 'activity' THEN
    SELECT * INTO r FROM public.retention_activity_log WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
    IF r.status <> 'void' THEN RETURN jsonb_build_object('ok', true, 'already_active', true); END IF;
    IF r.source <> 'manual' THEN RAISE EXCEPTION 'this credit belongs to a sale entry — restore the sale instead'; END IF;
    SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
    IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
    UPDATE public.retention_activity_log
       SET status='credited', voided_at=NULL, voided_by=NULL, void_reason=NULL, updated_at=now()
     WHERE id = p_id;
    RETURN jsonb_build_object('ok', true, 'id', p_id);
  END IF;

  IF v_kind = 'appointment' THEN
    SELECT * INTO r FROM public.appointment_log WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
    IF r.status <> 'void' THEN RETURN jsonb_build_object('ok', true, 'already_active', true); END IF;
    SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
    IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
    UPDATE public.appointment_log
       SET status='active', voided_at=NULL, voided_by=NULL, void_reason=NULL, updated_at=now()
     WHERE id = p_id;
    RETURN jsonb_build_object('ok', true, 'id', p_id);
  END IF;

  IF v_kind = 'cancelation' THEN
    SELECT * INTO r FROM public.cancelation_log WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
    IF r.status <> 'void' THEN RETURN jsonb_build_object('ok', true, 'already_active', true); END IF;
    SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
    IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
    UPDATE public.cancelation_log
       SET status='active', voided_at=NULL, voided_by=NULL, void_reason=NULL, updated_at=now()
     WHERE id = p_id;
    -- and the chargeback it caused goes back on
    IF r.chargeback_activity_id IS NOT NULL THEN
      UPDATE public.retention_activity_log
         SET status = CASE WHEN activity_key = 'multiline_chargeback' THEN 'credited' ELSE 'void' END,
             voided_at = CASE WHEN activity_key = 'multiline_chargeback' THEN NULL ELSE now() END,
             voided_by = CASE WHEN activity_key = 'multiline_chargeback' THEN NULL ELSE a.actor_id END,
             void_reason = CASE WHEN activity_key = 'multiline_chargeback' THEN NULL ELSE 'cancelation restored' END,
             updated_at = now()
       WHERE id = r.chargeback_activity_id;
    END IF;
    RETURN jsonb_build_object('ok', true, 'id', p_id);
  END IF;

  RAISE EXCEPTION 'unknown record type: %', p_kind;
END $function$;

-- Move a record to a different owner. Owner only, matching who may log on
-- someone else's behalf in rp_resolve_actor.
CREATE OR REPLACE FUNCTION public.rp_reassign_record(p_kind text, p_id uuid, p_team_member_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; v_kind text := lower(btrim(COALESCE(p_kind, ''))); v_agency uuid; v_n integer;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT COALESCE(public.current_app_user_role() = 'owner', false) THEN
    RAISE EXCEPTION 'only the owner can move a record to someone else' USING ERRCODE='42501';
  END IF;
  IF p_team_member_id IS NULL THEN RAISE EXCEPTION 'pick a team member' USING ERRCODE='22023'; END IF;
  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = p_team_member_id;
  IF v_agency IS DISTINCT FROM a.agency_id THEN RAISE EXCEPTION 'that person is not on this team'; END IF;

  IF v_kind = 'sale' THEN
    UPDATE public.sales_log SET team_member_id = p_team_member_id, updated_at = now()
     WHERE id = p_id AND agency_id = a.agency_id;
  ELSIF v_kind = 'quote' THEN
    UPDATE public.quote_log SET team_member_id = p_team_member_id, updated_at = now()
     WHERE id = p_id AND agency_id = a.agency_id;
  ELSIF v_kind = 'activity' THEN
    UPDATE public.retention_activity_log SET team_member_id = p_team_member_id, updated_at = now()
     WHERE id = p_id AND agency_id = a.agency_id;
  ELSIF v_kind = 'appointment' THEN
    UPDATE public.appointment_log SET team_member_id = p_team_member_id, updated_at = now()
     WHERE id = p_id AND agency_id = a.agency_id;
  ELSIF v_kind = 'cancelation' THEN
    UPDATE public.cancelation_log SET team_member_id = p_team_member_id, updated_at = now()
     WHERE id = p_id AND agency_id = a.agency_id;
  ELSE
    RAISE EXCEPTION 'unknown record type: %', p_kind;
  END IF;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN RAISE EXCEPTION 'not found'; END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_id, 'team_member_id', p_team_member_id);
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_list_removed(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_restore_record(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_reassign_record(text, uuid, uuid) TO authenticated;
