-- Peter 2026-09-20.
--
-- 1) A cancelation keyed in from the Backfill tab is history being recorded, not
--    someone on the team logging a cancelation as it happens. It must not pay the
--    0.50 "Cancelation Logged" credit to whoever owns the sale. cancelation_log
--    gets the same entry_source marker sales_log already has, and the credit
--    trigger skips anything marked historical_backfill.
--
-- 2) The backfill can mark an auto policy as a car added to a policy the
--    household already had. On a backfilled sale the credits are locked
--    (rp_derive_sale_credits returns early for anything not 'manual'), so this
--    only corrects the record; it moves no points.

ALTER TABLE public.cancelation_log ADD COLUMN IF NOT EXISTS entry_source text NOT NULL DEFAULT 'manual';

CREATE OR REPLACE FUNCTION public.cancelation_log_logging_credit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_pts numeric;
  v_cur_week date := public.rp_week_end(public.rp_today_central());
  v_week date;
BEGIN
  -- A cancelation that stops being active loses its credit.
  IF TG_OP = 'UPDATE' THEN
    IF NEW.status = 'active' OR OLD.status <> 'active' THEN RETURN NEW; END IF;
    UPDATE public.retention_activity_log
       SET status = 'void', voided_at = now(),
           void_reason = 'the cancelation it was credited for was removed', updated_at = now()
     WHERE source = 'cancelation_log' AND source_id = NEW.id
       AND activity_key = 'cancelation_logged' AND status = 'credited';
    RETURN NEW;
  END IF;

  IF NEW.status <> 'active' OR NEW.team_member_id IS NULL THEN RETURN NEW; END IF;
  -- History keyed in from the Backfill tab earns nobody a logging credit.
  IF COALESCE(NEW.entry_source, 'manual') = 'historical_backfill' THEN RETURN NEW; END IF;

  SELECT v.points INTO v_pts
    FROM public.retention_point_values v
   WHERE v.agency_id = NEW.agency_id AND v.activity_key = 'cancelation_logged' AND v.is_active;
  IF COALESCE(v_pts, 0) <= 0 THEN RETURN NEW; END IF;

  v_week := public.rp_week_end(NEW.canceled_on);

  INSERT INTO public.retention_activity_log (
    agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
    customer_first_name, customer_last_initial, customer_label, phone_last4,
    policy_line, product_type, note, points, source, source_id, created_by)
  VALUES (
    NEW.agency_id, NEW.team_member_id, 'cancelation_logged', NEW.canceled_on, v_week,
    GREATEST(v_week, v_cur_week),
    NEW.customer_first_name, NEW.customer_last_initial, NEW.customer_label, NEW.phone_last4,
    NEW.policy_line, NEW.product_type,
    'Logged the cancelation of ' || initcap(COALESCE(NEW.policy_line, '')) || ' ' || COALESCE(NEW.product_type, '')
      || ' on ' || to_char(NEW.canceled_on, 'Mon FMDD'),
    v_pts, 'cancelation_log', NEW.id, NEW.created_by);

  RETURN NEW;
END $function$;

-- rp_log_cancelation stamps the marker when the backfill flag is set.
DO $mig$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rp_log_cancelation';

  v_def := replace(v_def,
    'customer_label, policy_line, product_type, premium, vehicle_count, reason, note, created_by, matched_sale_product_id, is_replacement, ecrm_url)',
    'customer_label, policy_line, product_type, premium, vehicle_count, reason, note, created_by, matched_sale_product_id, is_replacement, ecrm_url, entry_source)');
  v_def := replace(v_def,
    'v_pref, COALESCE((p->>''replacement'')::boolean, false), v_ecrm)',
    'v_pref, COALESCE((p->>''replacement'')::boolean, false), v_ecrm, CASE WHEN v_backfill THEN ''historical_backfill'' ELSE ''manual'' END)');

  IF v_def NOT LIKE '%ecrm_url, entry_source)%' OR v_def NOT LIKE '%''historical_backfill'' ELSE ''manual'' END)%' THEN
    RAISE EXCEPTION 'rp_log_cancelation did not match the expected shape; not patching blind';
  END IF;
  EXECUTE v_def;
END $mig$;

-- rp_backfill_save learns the added-car flag. It sits beside the issue step,
-- before any cancelation, so the order of operations inside one save is:
-- household fields, premium and date, added car, then cancelation.
DO $mig$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rp_backfill_save';

  v_def := replace(v_def,
$old$    -- A policy marked canceled on a date he picked.$old$,
$new$    -- An auto policy that was a car added to a policy the household already
    -- had. Not a new line. Credits on a backfilled sale are locked, so this
    -- corrects the record and moves no points (Peter 2026-09-20).
    IF v_kind = 'sale' AND jsonb_typeof(rec->'policies') = 'array' THEN
      FOR pol IN SELECT * FROM jsonb_array_elements(rec->'policies') LOOP
        CONTINUE WHEN NOT (pol ? 'added_to_existing');
        UPDATE public.sales_log_products p
           SET is_added_to_existing = COALESCE((pol->>'added_to_existing')::boolean, false),
               is_new_line = NOT COALESCE((pol->>'added_to_existing')::boolean, false)
         WHERE p.id = (pol->>'id')::uuid AND p.sales_log_id = v_id AND p.agency_id = a.agency_id
           AND p.line_of_business = 'auto'
           AND p.is_added_to_existing IS DISTINCT FROM COALESCE((pol->>'added_to_existing')::boolean, false);
        GET DIAGNOSTICS n = ROW_COUNT;
        IF n > 0 THEN v_touched := true; END IF;
      END LOOP;
    END IF;

    -- A policy marked canceled on a date he picked.$new$);

  IF v_def NOT LIKE '%CONTINUE WHEN NOT (pol ? ''added_to_existing'')%' THEN
    RAISE EXCEPTION 'rp_backfill_save did not match the expected shape; not patching blind';
  END IF;
  EXECUTE v_def;
END $mig$;

-- The queue reports the flag per policy so the screen can show it.
DO $mig$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rp_backfill_queue';

  v_def := replace(v_def,
    $old$'needs_premium', (p.issued_date IS NOT NULL AND p.issued_premium IS NULL),$old$,
    $new$'needs_premium', (p.issued_date IS NOT NULL AND p.issued_premium IS NULL),
                        'added_to_existing', COALESCE(p.is_added_to_existing, false),$new$);

  IF v_def NOT LIKE '%''added_to_existing'', COALESCE(p.is_added_to_existing, false)%' THEN
    RAISE EXCEPTION 'rp_backfill_queue did not match the expected shape; not patching blind';
  END IF;
  EXECUTE v_def;
END $mig$;
