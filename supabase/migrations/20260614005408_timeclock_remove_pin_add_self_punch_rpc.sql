-- 1. Source CHECK: add 'self' (user punching themselves) and 'admin' (owner/manager
--    punching someone else, e.g. owner clocking the Test User).  Keep legacy values.
ALTER TABLE public.time_clock_entries
  DROP CONSTRAINT IF EXISTS time_clock_entries_source_check;
ALTER TABLE public.time_clock_entries
  ADD CONSTRAINT time_clock_entries_source_check
  CHECK (source = ANY (ARRAY['kiosk', 'admin_create', 'admin_edit', 'self', 'admin']));

-- 2. No-PIN punch RPC.  Uses auth.uid() to identify the caller; defaults target to
--    the caller's linked team row.  Owner/manager may pass an explicit
--    p_team_member_id to punch someone else (e.g. the Test User).  Non-admins
--    can only punch themselves.
CREATE OR REPLACE FUNCTION public.time_clock_punch_simple(
  p_team_member_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_auth_user_id uuid := auth.uid();
  v_caller       public.users%ROWTYPE;
  v_target_id    uuid;
  v_member       public.team%ROWTYPE;
  v_open         public.time_clock_entries%ROWTYPE;
  v_now          timestamptz := now();
  v_hours        numeric;
  v_source       text;
BEGIN
  IF v_auth_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT * INTO v_caller FROM public.users WHERE auth_user_id = v_auth_user_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_caller');
  END IF;

  -- Resolve target.  NULL means "punch myself."  Non-admins can't aim at anyone else.
  IF p_team_member_id IS NULL THEN
    v_target_id := v_caller.team_member_id;
    v_source := 'self';
  ELSE
    IF v_caller.role NOT IN ('owner','manager')
       AND p_team_member_id <> COALESCE(v_caller.team_member_id, '00000000-0000-0000-0000-000000000000'::uuid) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
    END IF;
    v_target_id := p_team_member_id;
    v_source := CASE
      WHEN p_team_member_id = v_caller.team_member_id THEN 'self'
      ELSE 'admin'
    END;
  END IF;

  IF v_target_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_team_member_linked');
  END IF;

  SELECT * INTO v_member FROM public.team WHERE id = v_target_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_team_member');
  END IF;
  IF v_member.agency_id <> v_caller.agency_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'agency_mismatch');
  END IF;
  IF v_member.is_active IS NOT TRUE OR v_member.archived_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'inactive_team_member');
  END IF;
  IF v_member.pay_type <> 'HOURLY' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_hourly');
  END IF;

  -- Toggle: open block => clock out; no open block => clock in
  SELECT * INTO v_open
  FROM public.time_clock_entries
  WHERE team_member_id = v_target_id AND clock_out_at IS NULL
  ORDER BY clock_in_at DESC LIMIT 1;

  IF FOUND THEN
    UPDATE public.time_clock_entries SET clock_out_at = v_now WHERE id = v_open.id;
    v_hours := EXTRACT(EPOCH FROM (v_now - v_open.clock_in_at)) / 3600.0;
    RETURN jsonb_build_object(
      'ok', true, 'action', 'clock_out',
      'team_member_name', v_member.first_name || ' ' || v_member.last_name,
      'at', v_now,
      'hours_this_block', round(v_hours::numeric, 2)
    );
  ELSE
    INSERT INTO public.time_clock_entries (agency_id, team_member_id, clock_in_at, source)
    VALUES (v_member.agency_id, v_target_id, v_now, v_source);
    RETURN jsonb_build_object(
      'ok', true, 'action', 'clock_in',
      'team_member_name', v_member.first_name || ' ' || v_member.last_name,
      'at', v_now
    );
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.time_clock_punch_simple(uuid) TO authenticated;
