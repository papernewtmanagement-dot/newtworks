-- 1. Leslie's monthly goals check-in gets a paid flag, so an answered month that
--    has already been paid can be told apart from one still owing.
ALTER TABLE public.leslie_monthly_checkin
  ADD COLUMN IF NOT EXISTS bonus_paid boolean NOT NULL DEFAULT false;

-- August 2026: Marie answered yes and the bonus was paid (Peter 2026-09-15).
-- marie_reply_at is left NULL on purpose -- the answer came in the group a while
-- back and the exact time is not known, so no timestamp is invented.
UPDATE public.leslie_monthly_checkin
SET marie_reply_text = 'Yes',
    bonus_paid = true,
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND review_month = '2026-08-01';

-- 2. team_payroll_week: name reads "Last, First"; rows sort hourly first then
--    salaried, alphabetical by last name inside each group; the goals block
--    carries the paid flag. Patched in place so nothing else shifts.
DO $mig$
DECLARE
  v_def text;
  v_old_name text := $a$      'name', TRIM(t.first_name || ' ' || COALESCE(t.last_name, '')),$a$;
  v_new_name text := $a$      'name', CASE WHEN COALESCE(t.last_name, '') = '' THEN t.first_name ELSE t.last_name || ', ' || t.first_name END,$a$;
  v_old_sortcols text := $b$    ) AS x
    FROM public.team t
    LEFT JOIN hrs  ON hrs.team_member_id  = t.id$b$;
  v_new_sortcols text := $b$    ) AS x,
    CASE WHEN t.pay_type = 'HOURLY' THEN 0 WHEN t.pay_type = 'SALARY' THEN 1 ELSE 2 END AS pay_ord,
    LOWER(COALESCE(t.last_name, '')) AS last_nm,
    LOWER(COALESCE(t.first_name, '')) AS first_nm
    FROM public.team t
    LEFT JOIN hrs  ON hrs.team_member_id  = t.id$b$;
  v_old_order text := $c$  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'name'), '[]'::jsonb)
    INTO v_people$c$;
  v_new_order text := $c$  SELECT COALESCE(jsonb_agg(x ORDER BY pay_ord, last_nm, first_nm), '[]'::jsonb)
    INTO v_people$c$;
  v_old_goals text := $d$    SELECT c.review_month, c.sent_at, c.sent_ok,$d$;
  v_new_goals text := $d$    SELECT c.review_month, c.sent_at, c.sent_ok, c.bonus_paid,$d$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'team_payroll_week';

  IF v_def IS NULL THEN RAISE EXCEPTION 'team_payroll_week not found'; END IF;
  IF position(v_old_name     in v_def) = 0 THEN RAISE EXCEPTION 'name expression did not match'; END IF;
  IF position(v_old_sortcols in v_def) = 0 THEN RAISE EXCEPTION 'roster select did not match'; END IF;
  IF position(v_old_order    in v_def) = 0 THEN RAISE EXCEPTION 'people ORDER BY did not match'; END IF;
  IF position(v_old_goals    in v_def) = 0 THEN RAISE EXCEPTION 'goals select did not match'; END IF;

  v_def := replace(v_def, v_old_name,     v_new_name);
  v_def := replace(v_def, v_old_sortcols, v_new_sortcols);
  v_def := replace(v_def, v_old_order,    v_new_order);
  v_def := replace(v_def, v_old_goals,    v_new_goals);

  EXECUTE v_def;
END
$mig$;
