-- =====================================================================
-- Signature auto-gen Phase 2: log table, dispatch RPC, auto-trigger
-- =====================================================================

-- 1. Send audit log
CREATE TABLE IF NOT EXISTS public.email_signature_sends (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  team_member_id uuid NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,
  recipient_email text NOT NULL,
  triggered_by text NOT NULL CHECK (triggered_by IN ('auto', 'manual')),
  status text NOT NULL CHECK (status IN ('sent', 'failed')),
  gmail_message_id text,
  error_message text,
  zip_size_bytes int,
  sent_at timestamptz NOT NULL DEFAULT NOW(),
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_email_signature_sends_member ON public.email_signature_sends (team_member_id, sent_at DESC);
CREATE INDEX IF NOT EXISTS idx_email_signature_sends_agency ON public.email_signature_sends (agency_id, sent_at DESC);

ALTER TABLE public.email_signature_sends ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "agency isolation" ON public.email_signature_sends;
CREATE POLICY "agency isolation" ON public.email_signature_sends
  FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- 2. Dispatch RPC — both auto-trigger and manual button call this
-- Fires the edge function via pg_net (fire-and-forget); the edge fn writes
-- the actual email_signature_sends row when it completes.
CREATE OR REPLACE FUNCTION public.send_signature_email(
  p_team_member_id uuid,
  p_triggered_by text DEFAULT 'manual',
  p_force boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_agency_id uuid;
  v_secret text;
  v_url text;
  v_request_id bigint;
BEGIN
  -- Resolve agency (single-agency system, but future-proofing)
  SELECT agency_id INTO v_agency_id FROM public.team WHERE id = p_team_member_id;
  IF v_agency_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'team member not found');
  END IF;

  -- Pull shared secret
  SELECT setting_value INTO v_secret
    FROM public.settings
    WHERE agency_id = v_agency_id AND setting_key = 'automation_runner_cron_secret';
  IF v_secret IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'automation_runner_cron_secret setting not configured');
  END IF;

  -- Build edge fn URL from settings (project_ref-derived) or fallback
  SELECT setting_value INTO v_url
    FROM public.settings
    WHERE agency_id = v_agency_id AND setting_key = 'supabase_functions_base_url';
  IF v_url IS NULL THEN
    v_url := 'https://vulhdujhbwvibbojiimi.supabase.co/functions/v1';
  END IF;

  -- Fire the edge function via pg_net (async, fire-and-forget)
  SELECT net.http_post(
    url := v_url || '/generate-signature',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object(
      'agency_id',      v_agency_id,
      'shared_secret',  v_secret,
      'team_member_id', p_team_member_id,
      'triggered_by',   p_triggered_by,
      'force',          p_force
    )
  ) INTO v_request_id;

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'dispatched',
    'request_id', v_request_id,
    'team_member_id', p_team_member_id,
    'triggered_by', p_triggered_by,
    'force', p_force
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.send_signature_email(uuid, text, boolean) TO authenticated;

-- 3. Auto-trigger on team INSERT/UPDATE
-- Fires when a category='agency' row transitions to "ready" state
-- (has email_sf + photo_storage_path + first_name + last_name populated)
-- and has never been sent before.
CREATE OR REPLACE FUNCTION public.tg_signature_auto_send()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prior_send_count int;
BEGIN
  -- Guard: only category='agency', not archived, all required fields present
  IF NEW.category IS DISTINCT FROM 'agency' THEN RETURN NEW; END IF;
  IF NEW.archived_at IS NOT NULL THEN RETURN NEW; END IF;
  IF NEW.email_sf IS NULL OR NEW.email_sf = '' THEN RETURN NEW; END IF;
  IF NEW.photo_storage_path IS NULL OR NEW.photo_storage_path = '' THEN RETURN NEW; END IF;
  IF NEW.first_name IS NULL OR NEW.first_name = '' THEN RETURN NEW; END IF;
  IF NEW.last_name IS NULL OR NEW.last_name = '' THEN RETURN NEW; END IF;

  -- Skip if already sent (auto-mode never re-sends silently)
  SELECT count(*) INTO v_prior_send_count
    FROM public.email_signature_sends
    WHERE team_member_id = NEW.id AND status = 'sent';
  IF v_prior_send_count > 0 THEN RETURN NEW; END IF;

  -- On UPDATE, only fire when we crossed the readiness threshold
  IF TG_OP = 'UPDATE' THEN
    IF OLD.email_sf IS NOT DISTINCT FROM NEW.email_sf
       AND OLD.photo_storage_path IS NOT DISTINCT FROM NEW.photo_storage_path
       AND OLD.first_name IS NOT DISTINCT FROM NEW.first_name
       AND OLD.last_name IS NOT DISTINCT FROM NEW.last_name
       AND OLD.category IS NOT DISTINCT FROM NEW.category
       AND OLD.archived_at IS NOT DISTINCT FROM NEW.archived_at
    THEN
      RETURN NEW;
    END IF;
  END IF;

  -- Dispatch (fire-and-forget)
  PERFORM public.send_signature_email(NEW.id, 'auto', false);

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tg_signature_auto_send_ins ON public.team;
CREATE TRIGGER tg_signature_auto_send_ins
  AFTER INSERT ON public.team
  FOR EACH ROW EXECUTE FUNCTION public.tg_signature_auto_send();

DROP TRIGGER IF EXISTS tg_signature_auto_send_upd ON public.team;
CREATE TRIGGER tg_signature_auto_send_upd
  AFTER UPDATE ON public.team
  FOR EACH ROW EXECUTE FUNCTION public.tg_signature_auto_send();
