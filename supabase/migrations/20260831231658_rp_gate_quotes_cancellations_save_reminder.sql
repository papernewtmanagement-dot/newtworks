-- Retention Points — items 2, 3, 4
-- 1. rp_program_live() gate
-- 2. quote_log -> weekly_cpr_team_detail.quotes_discussed (and stop the
--    Telegram check-in from overwriting it once the program is live)
-- 3. cancellation_log + rp_log_cancellation + void-unpaid-saves trigger
-- 4. rp_saves_clearing_soon view + run_rp_save_clear_reminder + recipe

-- ============================================================
-- 1. GATE
-- ============================================================
-- Single place that answers "is the points program in effect for this week".
-- Same logic compute_weekly_comp_residual_pool already uses inline: the
-- settings key holds the first week-ending Saturday the program counts for.
-- Empty key = not live, anywhere, ever. Only Peter sets it.
CREATE OR REPLACE FUNCTION public.rp_program_live(p_agency_id uuid, p_week_end_date date)
RETURNS boolean
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_go_live date;
BEGIN
  SELECT NULLIF(btrim(s.setting_value), '')::date
    INTO v_go_live
    FROM public.settings s
   WHERE s.agency_id = p_agency_id
     AND s.setting_key = 'retention_points_go_live_week_end';
  RETURN (v_go_live IS NOT NULL AND p_week_end_date >= v_go_live);
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END $fn$;

GRANT EXECUTE ON FUNCTION public.rp_program_live(uuid, date) TO authenticated;

-- ============================================================
-- 2. QUOTES FEED
-- ============================================================
-- Once the program is live, the quote count on the weekly report comes from
-- what people actually logged on the Activity Log page, not from the number
-- they type into the Telegram check-in.
CREATE OR REPLACE FUNCTION public.rp_sync_quotes_to_cpr_detail(
  p_agency_id uuid, p_team_member_id uuid, p_week_end_date date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_report_id uuid;
  v_detail_id uuid;
  v_count integer;
BEGIN
  IF p_agency_id IS NULL OR p_team_member_id IS NULL OR p_week_end_date IS NULL THEN
    RETURN;
  END IF;
  IF NOT public.rp_program_live(p_agency_id, p_week_end_date) THEN
    RETURN;
  END IF;

  SELECT COUNT(*)::integer INTO v_count
    FROM public.quote_log q
   WHERE q.agency_id = p_agency_id
     AND q.team_member_id = p_team_member_id
     AND q.week_end_date = p_week_end_date
     AND q.status = 'active';

  SELECT id INTO v_report_id
    FROM public.weekly_cpr_reports
   WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date;

  IF v_report_id IS NULL THEN
    INSERT INTO public.weekly_cpr_reports (agency_id, week_ending_date, created_at, updated_at)
    VALUES (p_agency_id, p_week_end_date, now(), now())
    RETURNING id INTO v_report_id;
  END IF;

  SELECT id INTO v_detail_id
    FROM public.weekly_cpr_team_detail
   WHERE weekly_cpr_report_id = v_report_id
     AND team_member_id = p_team_member_id;

  IF v_detail_id IS NULL THEN
    INSERT INTO public.weekly_cpr_team_detail
      (agency_id, weekly_cpr_report_id, team_member_id, quotes_discussed, created_at, updated_at)
    VALUES (p_agency_id, v_report_id, p_team_member_id, v_count, now(), now());
  ELSE
    UPDATE public.weekly_cpr_team_detail
       SET quotes_discussed = v_count, updated_at = now()
     WHERE id = v_detail_id;
  END IF;
END $fn$;

-- The per-row trigger only fires when a quote is logged. If the go-live date
-- is set part-way through a week, quotes already logged that week never fired
-- it. Run this once for that week and they land.
CREATE OR REPLACE FUNCTION public.rp_resync_quotes_week(p_agency_id uuid, p_week_end_date date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE rec RECORD; v_n integer := 0;
BEGIN
  IF NOT public.rp_program_live(p_agency_id, p_week_end_date) THEN
    RETURN jsonb_build_object('ok', true, 'synced', 0,
      'note', 'the points program is not live for that week, so nothing was written');
  END IF;
  FOR rec IN
    SELECT DISTINCT q.team_member_id
    FROM public.quote_log q
    WHERE q.agency_id = p_agency_id AND q.week_end_date = p_week_end_date
  LOOP
    PERFORM public.rp_sync_quotes_to_cpr_detail(p_agency_id, rec.team_member_id, p_week_end_date);
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'synced', v_n, 'week_end_date', p_week_end_date);
END $fn$;

CREATE OR REPLACE FUNCTION public.quote_log_sync_to_cpr_detail()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
BEGIN
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    PERFORM public.rp_sync_quotes_to_cpr_detail(NEW.agency_id, NEW.team_member_id, NEW.week_end_date);
  END IF;
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    IF TG_OP = 'DELETE'
       OR OLD.team_member_id IS DISTINCT FROM NEW.team_member_id
       OR OLD.week_end_date  IS DISTINCT FROM NEW.week_end_date THEN
      PERFORM public.rp_sync_quotes_to_cpr_detail(OLD.agency_id, OLD.team_member_id, OLD.week_end_date);
    END IF;
  END IF;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'quote_log_sync_to_cpr_detail: % (sqlstate %)', SQLERRM, SQLSTATE;
  RETURN NULL;
END $fn$;

DROP TRIGGER IF EXISTS trg_quote_log_sync_to_cpr_detail ON public.quote_log;
CREATE TRIGGER trg_quote_log_sync_to_cpr_detail
AFTER INSERT OR UPDATE OR DELETE ON public.quote_log
FOR EACH ROW EXECUTE FUNCTION public.quote_log_sync_to_cpr_detail();

-- Patched: identical to the shipped version except the quotes_discussed write
-- is skipped once the points program is live for that week. Sales points still
-- flow from the check-in as before.
CREATE OR REPLACE FUNCTION public.team_checkins_sync_to_cpr_detail()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_week_end       date;
  v_report_id      uuid;
  v_detail_id      uuid;
  v_quotes_live    boolean;
  v_quotes         integer;
BEGIN
  IF NEW.team_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF NEW.checkin_type NOT IN ('midday', 'eod') THEN
    RETURN NEW;
  END IF;
  IF NEW.quotes_week IS NULL AND NEW.sales_points_quarter IS NULL THEN
    RETURN NEW;
  END IF;

  v_week_end := NEW.checkin_date
              + ((6 - EXTRACT(DOW FROM NEW.checkin_date)::int) % 7);

  -- Once Retention Points is live the Activity Log owns the quote count.
  v_quotes_live := public.rp_program_live(NEW.agency_id, v_week_end);
  v_quotes := CASE
                WHEN v_quotes_live THEN NULL
                WHEN NEW.quotes_week IS NOT NULL THEN NEW.quotes_week::integer
                ELSE NULL
              END;

  SELECT id INTO v_report_id
  FROM public.weekly_cpr_reports
  WHERE agency_id = NEW.agency_id
    AND week_ending_date = v_week_end;

  IF v_report_id IS NULL THEN
    INSERT INTO public.weekly_cpr_reports (agency_id, week_ending_date, created_at, updated_at)
    VALUES (NEW.agency_id, v_week_end, now(), now())
    RETURNING id INTO v_report_id;
  END IF;

  SELECT id INTO v_detail_id
  FROM public.weekly_cpr_team_detail
  WHERE weekly_cpr_report_id = v_report_id
    AND team_member_id       = NEW.team_id;

  IF v_detail_id IS NULL THEN
    INSERT INTO public.weekly_cpr_team_detail (
      agency_id, weekly_cpr_report_id, team_member_id,
      quotes_discussed, sales_points,
      created_at, updated_at
    ) VALUES (
      NEW.agency_id, v_report_id, NEW.team_id,
      v_quotes,
      NEW.sales_points_quarter,
      now(), now()
    );
  ELSE
    UPDATE public.weekly_cpr_team_detail
       SET quotes_discussed = COALESCE(v_quotes, quotes_discussed),
           sales_points     = COALESCE(NEW.sales_points_quarter, sales_points),
           updated_at       = now()
     WHERE id = v_detail_id;
  END IF;

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'team_checkins_sync_to_cpr_detail: % (sqlstate %)', SQLERRM, SQLSTATE;
    RETURN NEW;
END;
$function$;

-- ============================================================
-- 3. CANCELLATIONS
-- ============================================================
-- A save earns its points only if the policy is still on the books 30 days
-- later. This is where a policy that cancelled anyway gets recorded, and it
-- takes back the save credit if that credit has not been paid yet.
CREATE TABLE IF NOT EXISTS public.cancellation_log (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id             uuid NOT NULL,
  team_member_id        uuid NOT NULL,
  cancelled_on          date NOT NULL,
  week_end_date         date NOT NULL,
  customer_first_name   text NOT NULL,
  customer_last_initial text NOT NULL,
  customer_label        text NOT NULL,
  policy_line           text NOT NULL,
  reason                text,
  note                  text,
  saves_voided          integer NOT NULL DEFAULT 0,
  status                text NOT NULL DEFAULT 'active',
  created_by            uuid,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  voided_at             timestamptz,
  voided_by             uuid,
  void_reason           text
);

CREATE INDEX IF NOT EXISTS idx_cancellation_log_agency_week
  ON public.cancellation_log (agency_id, week_end_date);
CREATE INDEX IF NOT EXISTS idx_cancellation_log_customer
  ON public.cancellation_log (agency_id, customer_label, policy_line);

ALTER TABLE public.cancellation_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cancellation_log_auth_read ON public.cancellation_log;
CREATE POLICY cancellation_log_auth_read ON public.cancellation_log
  FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

GRANT SELECT ON public.cancellation_log TO authenticated;

-- Takes back an unpaid save. "Unpaid" means the week the credit was going to
-- land is this week or later, so nothing has been paid out on it yet. A save
-- whose credit week has already closed is left alone.
CREATE OR REPLACE FUNCTION public.cancellation_log_void_unpaid_saves()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_n integer := 0;
BEGIN
  UPDATE public.retention_activity_log l
     SET status      = 'void',
         voided_at   = now(),
         voided_by   = NEW.created_by,
         void_reason = 'policy cancelled ' || NEW.cancelled_on::text || ' — the save did not hold',
         updated_at  = now()
   WHERE l.agency_id             = NEW.agency_id
     AND l.activity_key          = 'cancellation_saved'
     AND l.status                = 'credited'
     AND l.customer_label        = NEW.customer_label
     AND l.save_line             = NEW.policy_line
     AND l.occurred_on          <= NEW.cancelled_on
     AND l.credited_week_end_date >= public.rp_week_end(public.rp_today_central());
  GET DIAGNOSTICS v_n = ROW_COUNT;
  NEW.saves_voided := v_n;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_cancellation_log_void_unpaid_saves ON public.cancellation_log;
CREATE TRIGGER trg_cancellation_log_void_unpaid_saves
BEFORE INSERT ON public.cancellation_log
FOR EACH ROW EXECUTE FUNCTION public.cancellation_log_void_unpaid_saves();

CREATE OR REPLACE FUNCTION public.rp_log_cancellation(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  a RECORD;
  p jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_today date := public.rp_today_central();
  v_on date; v_label text; v_line text; v_reason text; v_note text;
  v_id uuid; v_voided integer;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  v_on := COALESCE(NULLIF(p->>'cancelled_on','')::date, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'the cancellation date cannot be in the future'; END IF;
  IF v_on < v_today - 90 THEN RAISE EXCEPTION 'log a cancellation within 90 days of the date it happened'; END IF;

  v_label := public.rp_customer_label(p->>'customer_first', p->>'customer_last_initial');
  v_line  := NULLIF(lower(btrim(COALESCE(p->>'policy_line',''))), '');
  IF v_line IS NULL OR v_line NOT IN ('auto','fire','business','life','health','ips','bank') THEN
    RAISE EXCEPTION 'pick the policy line that cancelled';
  END IF;
  v_reason := NULLIF(btrim(COALESCE(p->>'reason','')), '');
  v_note   := NULLIF(btrim(COALESCE(p->>'note','')), '');

  INSERT INTO public.cancellation_log
    (agency_id, team_member_id, cancelled_on, week_end_date,
     customer_first_name, customer_last_initial, customer_label,
     policy_line, reason, note, created_by)
  VALUES
    (a.agency_id, a.team_member_id, v_on, public.rp_week_end(v_on),
     btrim(p->>'customer_first'), upper(btrim(p->>'customer_last_initial')), v_label,
     v_line, v_reason, v_note, a.actor_id)
  RETURNING id, saves_voided INTO v_id, v_voided;

  RETURN jsonb_build_object('ok', true, 'cancellation_id', v_id, 'customer', v_label,
                            'policy_line', v_line, 'saves_voided', v_voided);
END $fn$;

GRANT EXECUTE ON FUNCTION public.rp_log_cancellation(jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.rp_void_cancellation(p_id uuid, p_reason text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE a RECORD; r RECORD;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  SELECT * INTO r FROM public.cancellation_log WHERE id = p_id AND agency_id = a.agency_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status = 'void' THEN RETURN jsonb_build_object('ok', true, 'already_void', true); END IF;
  IF NOT a.is_admin THEN
    IF r.team_member_id <> a.actor_id THEN
      RAISE EXCEPTION 'you can only remove your own entries' USING ERRCODE='42501';
    END IF;
    IF r.created_at < now() - interval '7 days' THEN
      RAISE EXCEPTION 'entries older than 7 days can only be removed by an admin' USING ERRCODE='42501';
    END IF;
  END IF;
  UPDATE public.cancellation_log
     SET status='void', voided_at=now(), voided_by=a.actor_id,
         void_reason=NULLIF(btrim(COALESCE(p_reason,'')),''), updated_at=now()
   WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'id', p_id,
    'note', 'removing the cancellation does not put back a save it took away — log the save again if that is what you meant');
END $fn$;

GRANT EXECUTE ON FUNCTION public.rp_void_cancellation(uuid, text) TO authenticated;

-- ============================================================
-- 4. SAVES CLEARING SOON
-- ============================================================
CREATE OR REPLACE VIEW public.rp_saves_clearing_soon
WITH (security_invoker = true) AS
SELECT l.id,
       l.agency_id,
       l.team_member_id,
       t.first_name,
       l.customer_label,
       l.save_line,
       l.save_reason,
       l.occurred_on,
       l.credit_available_on,
       l.credited_week_end_date,
       l.points,
       (l.credit_available_on - public.rp_today_central()) AS days_until_clear
FROM public.retention_activity_log l
LEFT JOIN public.team t ON t.id = l.team_member_id
WHERE l.activity_key = 'cancellation_saved'
  AND l.status = 'credited'
  AND l.verified_at IS NULL
  AND l.credit_available_on IS NOT NULL
  AND l.credit_available_on >= public.rp_today_central();

GRANT SELECT ON public.rp_saves_clearing_soon TO authenticated;

-- Three days before a save clears, put it in front of somebody: is the policy
-- still on the books? If it is not, log the cancellation and the credit comes
-- back off before it is ever paid.
CREATE OR REPLACE FUNCTION public.run_rp_save_clear_reminder(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  rec RECORD;
  v_count integer := 0;
  v_ref text;
BEGIN
  FOR rec IN
    SELECT s.id, s.first_name, s.customer_label, s.save_line,
           s.credit_available_on, s.days_until_clear
    FROM public.rp_saves_clearing_soon s
    WHERE s.agency_id = p_agency_id
      AND s.days_until_clear BETWEEN 0 AND 3
  LOOP
    v_ref := 'retention_points:save_clear:' || rec.id::text;
    IF NOT EXISTS (
      SELECT 1 FROM public.alerts a
      WHERE a.agency_id = p_agency_id
        AND a.module_reference = v_ref
        AND a.is_resolved IS NOT TRUE
    ) THEN
      INSERT INTO public.alerts
        (id, agency_id, alert_type, severity, title, message,
         module_reference, related_id, is_read, is_resolved, created_at)
      VALUES (
        gen_random_uuid(), p_agency_id, 'rp_save_clearing', 'low',
        COALESCE(rec.first_name, 'A teammate') || ' — ' || rec.customer_label ||
          ' save clears ' || to_char(rec.credit_available_on, 'Mon FMDD'),
        'The ' || rec.save_line || ' policy for ' || rec.customer_label ||
          ' was saved 30 days ago and the credit lands on ' ||
          to_char(rec.credit_available_on, 'Mon FMDD') || '. Check the policy is still active. ' ||
          'If it cancelled anyway, log the cancellation on the Activity Log page and the credit comes back off before it is paid.',
        v_ref, rec.id, false, false, now()
      );
      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'records_processed', v_count,
    'output_summary', v_count || ' save-clearing reminder(s) raised'
  );
END $fn$;

INSERT INTO public.automation_recipes
  (agency_id, recipe_name, recipe_description, trigger_type, cron_expression, timezone,
   composio_action, internal_handler, input_config, is_active)
SELECT '126794dd-25ff-47d2-a436-724499733365'::uuid,
       'Retention Points — Save Clearing Reminder',
       'Three days before a cancellation save clears its 30 days, raise an alert so someone confirms the policy is still active.',
       'cron', '0 8 * * *', 'America/Chicago',
       'INTERNAL', 'run_rp_save_clear_reminder',
       jsonb_build_object('description', 'Calls public.run_rp_save_clear_reminder(agency_id, recipe_id).'),
       true
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND internal_handler = 'run_rp_save_clear_reminder'
);
