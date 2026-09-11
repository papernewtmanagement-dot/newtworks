-- Change log for the Production module.
-- Peter 2026-09-10: "We need a track record of changes so that we can see who changed
-- what and when." Every insert, update and delete on the seven Production tables lands
-- in public.change_log with the full row before and after, who did it, how, and when.
-- Triggers catch app writes, maintenance SQL and automation alike, so a correction run
-- by hand leaves the same trail as a click on the page. Undo (rp_undo_entry) deletes
-- rows; the deleted rows are kept here in old_row.

CREATE TABLE IF NOT EXISTS public.change_log (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id                 uuid NOT NULL,
  table_name                text NOT NULL,
  row_id                    uuid NOT NULL,
  action                    text NOT NULL CHECK (action IN ('insert', 'update', 'delete')),
  changed_at                timestamptz NOT NULL DEFAULT now(),
  txid                      bigint NOT NULL DEFAULT txid_current(),  -- one Log click = one txid, so an entry's rows group together
  changed_by_user_id        uuid,          -- public.users.id when the change came through the app
  changed_by_team_member_id uuid,          -- public.team.id for that user, when there is one
  changed_by_label          text NOT NULL, -- the person's name, or 'Maintenance (SQL)', or 'Automation (...)'
  via                       text NOT NULL CHECK (via IN ('app', 'maintenance', 'automation')),
  subject                   text,          -- the customer the row is about (label, or parent's label for policy rows)
  changed_fields            text[],        -- updates only: which columns moved (updated_at ignored)
  old_row                   jsonb,         -- update + delete
  new_row                   jsonb          -- insert + update
);

CREATE INDEX IF NOT EXISTS change_log_agency_time_idx ON public.change_log (agency_id, changed_at DESC);
CREATE INDEX IF NOT EXISTS change_log_row_idx        ON public.change_log (table_name, row_id, changed_at DESC);

ALTER TABLE public.change_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS change_log_admin_read ON public.change_log;
CREATE POLICY change_log_admin_read ON public.change_log
  FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND public.is_agency_admin());
-- No insert/update/delete policy on purpose: only the trigger writes here.

CREATE OR REPLACE FUNCTION public.log_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_old     jsonb;
  v_new     jsonb;
  v_row     jsonb;
  v_fields  text[];
  v_uid     uuid;
  v_user_id uuid;
  v_tm      uuid;
  v_label   text;
  v_via     text;
  v_subject text;
  v_appname text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_new := to_jsonb(NEW); v_row := v_new;
  ELSIF TG_OP = 'DELETE' THEN
    v_old := to_jsonb(OLD); v_row := v_old;
  ELSE
    v_old := to_jsonb(OLD); v_new := to_jsonb(NEW); v_row := v_new;
    SELECT array_agg(k ORDER BY k) INTO v_fields
      FROM jsonb_object_keys(v_new) AS k
     WHERE k <> 'updated_at' AND (v_new -> k) IS DISTINCT FROM (v_old -> k);
    IF v_fields IS NULL THEN
      RETURN NULL;  -- nothing moved but the clock
    END IF;
  END IF;

  -- Who did it.
  BEGIN
    v_uid := auth.uid();
  EXCEPTION WHEN OTHERS THEN
    v_uid := NULL;
  END;
  v_appname := COALESCE(current_setting('application_name', true), '');

  IF v_uid IS NOT NULL THEN
    SELECT u.id, u.team_member_id, COALESCE(NULLIF(btrim(u.full_name), ''), u.email)
      INTO v_user_id, v_tm, v_label
      FROM public.users u
     WHERE u.auth_user_id = v_uid
     LIMIT 1;
    IF v_tm IS NULL AND v_user_id IS NOT NULL THEN
      SELECT t.id INTO v_tm FROM public.team t
       WHERE t.user_id = v_user_id AND t.archived_at IS NULL
       LIMIT 1;
    END IF;
    v_via   := 'app';
    v_label := COALESCE(v_label, 'App user ' || left(v_uid::text, 8));
  ELSIF v_appname ILIKE 'pg_cron%' THEN
    v_via   := 'automation';
    v_label := 'Automation (scheduled)';
  ELSIF current_user IN ('postgres', 'supabase_admin') THEN
    v_via   := 'maintenance';
    v_label := 'Maintenance (SQL)';
  ELSE
    v_via   := 'automation';
    v_label := 'Automation (' || current_user || ')';
  END IF;

  -- Which customer the row is about.
  v_subject := COALESCE(
    NULLIF(btrim(COALESCE(v_row ->> 'customer_label', '')), ''),
    NULLIF(btrim(COALESCE(v_row ->> 'customer_first_name', '') || ' ' || COALESCE(v_row ->> 'customer_last_initial', '')), '')
  );
  IF v_subject IS NULL AND TG_TABLE_NAME = 'sales_log_products' THEN
    SELECT s.customer_label INTO v_subject FROM public.sales_log s WHERE s.id = (v_row ->> 'sales_log_id')::uuid;
  ELSIF v_subject IS NULL AND TG_TABLE_NAME = 'quote_log_products' THEN
    SELECT q.customer_label INTO v_subject FROM public.quote_log q WHERE q.id = (v_row ->> 'quote_log_id')::uuid;
  END IF;

  INSERT INTO public.change_log
    (agency_id, table_name, row_id, action, changed_by_user_id, changed_by_team_member_id,
     changed_by_label, via, subject, changed_fields, old_row, new_row)
  VALUES
    ((v_row ->> 'agency_id')::uuid, TG_TABLE_NAME, (v_row ->> 'id')::uuid, lower(TG_OP), v_user_id, v_tm,
     v_label, v_via, v_subject, v_fields, v_old, v_new);
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  -- Never block the team's write because the trail failed; shout in the log instead.
  RAISE WARNING 'change_log: % on %: %', TG_OP, TG_TABLE_NAME, SQLERRM;
  RETURN NULL;
END
$fn$;

DO $do$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['sales_log', 'sales_log_products', 'quote_log', 'quote_log_products',
                           'cancelation_log', 'retention_activity_log', 'fit_scorecards'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_change_log ON public.%I', t);
    EXECUTE format('CREATE TRIGGER trg_change_log AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.log_change()', t);
  END LOOP;
END
$do$;

-- Reader for the page. Runs as the caller, so the admin-only read policy applies.
-- p_team_member_id matches either the person who made the change or the person whose entry changed.
CREATE OR REPLACE FUNCTION public.change_log_recent(
  p_days           integer DEFAULT 30,
  p_team_member_id uuid    DEFAULT NULL,
  p_limit          integer DEFAULT 300
)
RETURNS TABLE (
  id             uuid,
  changed_at     timestamptz,
  txid           bigint,
  who            text,
  via            text,
  action         text,
  item           text,
  table_name     text,
  row_id         uuid,
  subject        text,
  changed_fields text[],
  old_row        jsonb,
  new_row        jsonb
)
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $fn$
  SELECT c.id, c.changed_at, c.txid, c.changed_by_label, c.via, c.action,
         CASE c.table_name
           WHEN 'sales_log'              THEN 'Sale'
           WHEN 'sales_log_products'     THEN 'Sold policy'
           WHEN 'quote_log'              THEN 'Quote'
           WHEN 'quote_log_products'     THEN 'Quoted product'
           WHEN 'cancelation_log'        THEN 'Cancelation'
           WHEN 'retention_activity_log' THEN 'Activity'
           WHEN 'fit_scorecards'         THEN 'FIT scorecard'
           ELSE c.table_name
         END,
         c.table_name, c.row_id, c.subject, c.changed_fields, c.old_row, c.new_row
    FROM public.change_log c
   WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
     AND c.changed_at >= now() - make_interval(days => GREATEST(COALESCE(p_days, 30), 1))
     AND (p_team_member_id IS NULL
          OR c.changed_by_team_member_id = p_team_member_id
          OR (COALESCE(c.new_row, c.old_row) ->> 'team_member_id') = p_team_member_id::text)
   ORDER BY c.changed_at DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 300), 1), 1000);
$fn$;

COMMENT ON TABLE public.change_log IS
  'Who changed what and when on the Production tables (sales, sold policies, quotes, quoted products, cancelations, activities, FIT scorecards). Written only by trigger trg_change_log via public.log_change(). Admin read only. Peter 2026-09-10.';