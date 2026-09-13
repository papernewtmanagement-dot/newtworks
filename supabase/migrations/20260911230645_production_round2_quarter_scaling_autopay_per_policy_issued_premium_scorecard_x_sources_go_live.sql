-- Production module round 2 (Peter 2026-09-11): scaling counts priors within the quarter (same as Sales Points),
-- autopay per policy at $3 with a one-credit-per-policy guard, issued premium required on To be issued, scorecard
-- x/1/2/3 with a derived average, marketing sources reshaped, product labels, go-live, CPR scorecard requirement
-- satisfied by Production entries once live.

-- 1. Scaling window = the quarter (current_cycle_info), for Retention Points and marketing points alike.
CREATE OR REPLACE FUNCTION public.rp_scale_points_by_prior()
RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_pct numeric; v_cap integer; v_prior integer; v_start date;
BEGIN
  IF NEW.points IS NULL OR NEW.points <= 0 THEN RETURN NEW; END IF;
  SELECT COALESCE(v.prior_step_pct, 0), COALESCE(v.prior_cap, 0) INTO v_pct, v_cap
  FROM public.retention_point_values v WHERE v.agency_id = NEW.agency_id AND v.activity_key = NEW.activity_key;
  IF NOT FOUND OR v_pct <= 0 OR v_cap <= 0 THEN RETURN NEW; END IF;
  SELECT c.cycle_start INTO v_start FROM public.current_cycle_info(NEW.agency_id, NEW.occurred_on) c;
  v_start := COALESCE(v_start, date_trunc('quarter', NEW.occurred_on)::date);
  SELECT count(*) INTO v_prior FROM public.retention_activity_log p
  WHERE p.agency_id = NEW.agency_id AND p.team_member_id = NEW.team_member_id AND p.activity_key = NEW.activity_key
    AND p.status <> 'voided' AND p.points > 0
    AND p.occurred_on >= v_start AND p.occurred_on <= NEW.occurred_on;
  NEW.points := ROUND(NEW.points * (1 + (v_pct / 100.0) * LEAST(v_cap, v_prior)), 2);
  RETURN NEW;
END $$;
UPDATE public.marketing_point_values SET description = replace(description, 'this year', 'this quarter'), updated_at = now() WHERE description LIKE '%this year%';

-- 2. Autopay per policy. $3 per policy (was $5 per household). On a sale the policy carries autopay_enrolled; a
--    retention entry carries the line, type and premium. One credit per customer + line (+ type); the guard below
--    rejects a second one whichever side logs it.
ALTER TABLE public.sales_log_products ADD COLUMN IF NOT EXISTS autopay_enrolled boolean NOT NULL DEFAULT false;
ALTER TABLE public.sales_log_products ADD COLUMN IF NOT EXISTS issued_premium numeric;
ALTER TABLE public.retention_activity_log ADD COLUMN IF NOT EXISTS policy_line text;
ALTER TABLE public.retention_activity_log ADD COLUMN IF NOT EXISTS product_type text;
ALTER TABLE public.retention_activity_log ADD COLUMN IF NOT EXISTS premium numeric;
UPDATE public.retention_point_values SET points = 3.00, updated_at = now(),
  description = 'A policy that was not on automatic payment is now on it because you set it up. One credit per policy: on a sale, tick Autopay on the policy; for a policy already on the books, pick its line, type and premium.'
WHERE activity_key = 'autopay_enrollment';

CREATE OR REPLACE FUNCTION public.rp_autopay_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_prior record;
BEGIN
  IF NEW.activity_key <> 'autopay_enrollment' OR COALESCE(NEW.status, 'credited') = 'voided' THEN RETURN NEW; END IF;
  IF NEW.policy_line IS NULL THEN RAISE EXCEPTION 'Autopay needs the policy line it was set up on'; END IF;
  IF NEW.premium IS NULL OR NEW.premium < 0 THEN RAISE EXCEPTION 'Autopay needs the policy premium'; END IF;
  SELECT l.occurred_on, l.source INTO v_prior FROM public.retention_activity_log l
   WHERE l.agency_id = NEW.agency_id AND l.activity_key = 'autopay_enrollment' AND l.status <> 'voided'
     AND l.customer_label = NEW.customer_label AND l.policy_line = NEW.policy_line
     AND (l.product_type IS NULL OR NEW.product_type IS NULL OR l.product_type = NEW.product_type)
   ORDER BY l.occurred_on DESC LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Autopay for % on % is already credited (% %). One autopay credit per policy.',
      NEW.customer_label, NEW.policy_line, CASE WHEN v_prior.source = 'manual' THEN 'logged' ELSE 'from the sale on' END, to_char(v_prior.occurred_on, 'Mon FMDD');
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_rp_autopay_guard ON public.retention_activity_log;
CREATE TRIGGER trg_rp_autopay_guard BEFORE INSERT ON public.retention_activity_log
FOR EACH ROW EXECUTE FUNCTION public.rp_autopay_guard();

-- sale side: a sold policy ticked Autopay writes the credit to the seller, riding on the sale (undo/void follow the sale)
CREATE OR REPLACE FUNCTION public.rp_sale_autopay_credit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
BEGIN
  IF NOT NEW.autopay_enrolled THEN RETURN NEW; END IF;
  INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
      customer_first_name, customer_last_initial, customer_label, ecrm_url, note, points, source, source_id, created_by,
      policy_line, product_type, premium)
  SELECT s.agency_id, s.team_member_id, 'autopay_enrollment', s.submitted_date, public.rp_week_end(s.submitted_date), public.rp_week_end(s.submitted_date),
         s.customer_first_name, s.customer_last_initial, s.customer_label, s.ecrm_opportunity_url, 'From sale entry: policy set up on autopay',
         v.points, 'sales_log', s.id, s.created_by, NEW.line_of_business, NEW.product_type, NEW.premium
  FROM public.sales_log s
  JOIN public.retention_point_values v ON v.agency_id = s.agency_id AND v.activity_key = 'autopay_enrollment' AND v.is_active
  WHERE s.id = NEW.sales_log_id;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_rp_sale_autopay_credit ON public.sales_log_products;
CREATE TRIGGER trg_rp_sale_autopay_credit AFTER INSERT ON public.sales_log_products
FOR EACH ROW EXECUTE FUNCTION public.rp_sale_autopay_credit();

-- rp_log_activity: carry policy_line / product_type / premium from the item; the same-day duplicate check steps aside
-- for autopay (the guard checks per policy instead).
DO $$
DECLARE d text; o1 text; n1 text; o2 text; n2 text; o3 text; n3 text;
BEGIN
  d := pg_get_functiondef('public.rp_log_activity'::regproc);
  o1 := E'IF EXISTS (SELECT 1 FROM public.retention_activity_log l\n               WHERE l.agency_id = a.agency_id AND l.team_member_id = a.team_member_id';
  n1 := E'IF v_key <> ''autopay_enrollment'' AND EXISTS (SELECT 1 FROM public.retention_activity_log l\n               WHERE l.agency_id = a.agency_id AND l.team_member_id = a.team_member_id';
  o2 := 'save_reason, save_line, points, source, created_by)';
  n2 := 'save_reason, save_line, points, source, created_by, policy_line, product_type, premium)';
  o3 := E'v_reason, v_line, v.points, ''manual'', a.actor_id)';
  n3 := E'v_reason, v_line, v.points, ''manual'', a.actor_id,\n       NULLIF(lower(btrim(COALESCE(item->>''policy_line'',''''))), ''''), NULLIF(btrim(COALESCE(item->>''product_type'','''')), ''''), NULLIF(item->>''premium'','''')::numeric)';
  IF position(o1 in d) = 0 OR position(o2 in d) = 0 OR position(o3 in d) = 0 THEN RAISE EXCEPTION 'rp_log_activity patch anchors not found'; END IF;
  d := replace(replace(replace(d, o1, n1), o2, n2), o3, n3);
  EXECUTE d;
END $$;

-- rp_log_sale: the product row carries autopay from the payload (autopay: true on a sold policy)
DO $$
DECLARE d text; o1 text; n1 text;
BEGIN
  d := pg_get_functiondef('public.rp_log_sale'::regproc);
  o1 := E'is_new_line, multiline_credit_id, issued_date)\n    VALUES (v_sale_id, a.agency_id, v_lob, v_type, v_prem, v_cnt, v_veh, v_new, v_credit_id, NULLIF(prod->>''issued_date'','''')::date);';
  n1 := E'is_new_line, multiline_credit_id, issued_date, autopay_enrolled)\n    VALUES (v_sale_id, a.agency_id, v_lob, v_type, v_prem, v_cnt, v_veh, v_new, v_credit_id, NULLIF(prod->>''issued_date'','''')::date, COALESCE((prod->>''autopay'')::boolean, false));';
  IF position(o1 in d) = 0 THEN RAISE EXCEPTION 'rp_log_sale patch anchor not found'; END IF;
  EXECUTE replace(d, o1, n1);
END $$;

-- 3. To be issued requires the issued premium; Sales Points use it once it is there.
CREATE OR REPLACE FUNCTION public.rp_mark_issued(p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE
  a RECORD; it jsonb; v_id uuid; v_on date; v_sub date; v_prem numeric; v_n integer := 0;
  v_today date := public.rp_today_central();
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'pick at least one policy to mark issued';
  END IF;
  FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_id := NULLIF(it->>'sale_product_id','')::uuid;
    v_on := COALESCE(NULLIF(it->>'issued_date','')::date, v_today);
    v_prem := NULLIF(it->>'issued_premium','')::numeric;
    IF v_on > v_today THEN RAISE EXCEPTION 'the issue date cannot be in the future'; END IF;
    IF v_prem IS NULL OR v_prem < 0 THEN RAISE EXCEPTION 'enter the issued premium'; END IF;
    IF v_prem > 1000000 THEN RAISE EXCEPTION 'the issued premium looks too large. Double-check it.'; END IF;
    SELECT s.submitted_date INTO v_sub
      FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
     WHERE p.id = v_id AND s.agency_id = a.agency_id AND s.status = 'active';
    IF v_sub IS NULL THEN RAISE EXCEPTION 'that policy was not found'; END IF;
    IF v_on < v_sub THEN RAISE EXCEPTION 'a policy cannot issue before it was submitted (submitted %)', v_sub; END IF;
    UPDATE public.sales_log_products SET issued_date = v_on, issued_premium = v_prem WHERE id = v_id;
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'marked', v_n);
END $$;

-- 4. Scorecard: x (stored 0) means "did not do it"; 1 poorly and it did not land; 2 well but it did not land;
--    3 well and it landed. The average ignores x.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT conname, regexp_replace(conname, '^fit_scorecards_(.*)_check$', '\1') AS col
           FROM pg_constraint WHERE conrelid = 'public.fit_scorecards'::regclass AND contype = 'c' AND conname LIKE 'fit_scorecards_%_score_check' LOOP
    EXECUTE format('ALTER TABLE public.fit_scorecards DROP CONSTRAINT %I', r.conname);
    EXECUTE format('ALTER TABLE public.fit_scorecards ADD CONSTRAINT %I CHECK (%I IS NULL OR (%I >= 0 AND %I <= 3))', r.conname, r.col, r.col, r.col);
  END LOOP;
END $$;
CREATE OR REPLACE FUNCTION public.fit_scorecards_average()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s numeric := 0; n integer := 0; v integer;
BEGIN
  FOREACH v IN ARRAY ARRAY[NEW.demeanor_score, NEW.frogs_score, NEW.intro_score, NEW.eligibility_score, NEW.setup_gnc_score,
                           NEW.uncover_gap_score, NEW.bridge_gap_score, NEW.customize_close_score, NEW.set_followup_score, NEW.review_referral_score] LOOP
    IF v IS NOT NULL AND v > 0 THEN s := s + v; n := n + 1; END IF;
  END LOOP;
  NEW.average_score := CASE WHEN n > 0 THEN ROUND(s / n, 2) ELSE NULL END;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_fit_scorecards_average ON public.fit_scorecards;
CREATE TRIGGER trg_fit_scorecards_average BEFORE INSERT OR UPDATE ON public.fit_scorecards
FOR EACH ROW EXECUTE FUNCTION public.fit_scorecards_average();

-- 5. Marketing sources: drop Agency website (history -> StateFarm.com), Existing customer (history -> Policy Review),
--    Called the office (history -> Social media); add Policy Review, Service Pivot, Billboard.
INSERT INTO public.sales_marketing_sources (agency_id, source_key, label, sort_order, is_active)
SELECT a.agency_id, v.source_key, v.label, v.sort_order, true
FROM (VALUES ('policy_review', 'Policy Review', 15), ('service_pivot', 'Service Pivot', 18), ('billboard', 'Billboard', 135)) AS v(source_key, label, sort_order)
CROSS JOIN (SELECT DISTINCT agency_id FROM public.sales_marketing_sources) a
ON CONFLICT DO NOTHING;
UPDATE public.sales_marketing_sources SET is_active = false WHERE source_key IN ('website', 'existing_customer', 'call_in');
UPDATE public.sales_log SET marketing_source = CASE marketing_source WHEN 'website' THEN 'statefarm_com' WHEN 'existing_customer' THEN 'policy_review' WHEN 'call_in' THEN 'social_media' END
WHERE marketing_source IN ('website', 'existing_customer', 'call_in');
UPDATE public.quote_log SET marketing_source = CASE marketing_source WHEN 'website' THEN 'statefarm_com' WHEN 'existing_customer' THEN 'policy_review' WHEN 'call_in' THEN 'social_media' END
WHERE marketing_source IN ('website', 'existing_customer', 'call_in');

-- 6. Product labels.
UPDATE public.product_types SET label = 'BOP' WHERE type_key = 'business_insurance' AND line_of_business = 'fire';
UPDATE public.product_types SET label = 'Condo' WHERE type_key = 'condo' AND line_of_business = 'fire';

-- 7. Go live: logging starts the week of Sep 13, so the first live week ends 2026-09-19.
UPDATE public.settings SET setting_value = '2026-09-19' WHERE setting_key = 'retention_points_go_live_week_end';
INSERT INTO public.settings (agency_id, setting_key, setting_value)
SELECT a.agency_id, 'retention_points_go_live_week_end', '2026-09-19'
FROM (SELECT DISTINCT agency_id FROM public.retention_point_values) a
WHERE NOT EXISTS (SELECT 1 FROM public.settings s WHERE s.agency_id = a.agency_id AND s.setting_key = 'retention_points_go_live_week_end');

-- 8. CPR scorecard requirement: satisfied once the program is live (the scorecard is required on the Production entry).
DO $$
DECLARE d text; o1 text; n1 text;
BEGIN
  d := pg_get_functiondef('public.compute_scorecard_done_for_cpr_week'::regproc);
  o1 := '(f.matching_count >= f.threshold) AS done';
  n1 := '(f.matching_count >= f.threshold OR public.rp_program_live(p_agency_id, p_week_ending_date)) AS done';
  IF position(o1 in d) = 0 THEN RAISE EXCEPTION 'compute_scorecard_done_for_cpr_week patch anchor not found'; END IF;
  EXECUTE replace(d, o1, n1);
END $$;

-- 9. Scoreboard: quarter window for marketing priors, issued premium for Sales Points.
CREATE OR REPLACE FUNCTION public.rp_week_scoreboard_for(p_agency_id uuid, p_week_end date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE
  v_week_end   date := public.rp_week_end(p_week_end);
  v_week_start date := public.rp_week_end(p_week_end) - 6;
  v_prev_end   date := public.rp_week_end(p_week_end) - 7;
  v_cycle_start date;
  v_people jsonb;
  v_team jsonb;
BEGIN
  SELECT c.cycle_start INTO v_cycle_start FROM public.current_cycle_info(p_agency_id, v_week_end) c;
  v_cycle_start := COALESCE(v_cycle_start, date_trunc('quarter', v_week_end)::date);

  WITH roster AS (
    SELECT t.id, t.first_name, t.role_category
    FROM public.team t
    WHERE t.agency_id = p_agency_id AND t.is_active AND t.archived_at IS NULL
      AND COALESCE(t.is_test_user, false) = false AND COALESCE(t.is_admin_backoffice, false) = false
      AND (t.role_level IS NULL OR t.role_level <> 'Owner') AND t.category = 'agency'
      AND (t.end_date IS NULL OR t.end_date >= v_week_start)
  ),
  labels AS (SELECT v.activity_key, v.label FROM public.retention_point_values v WHERE v.agency_id = p_agency_id),
  mv AS (SELECT m.event_key, m.label, m.base_points, m.step_per_prior, m.prior_cap FROM public.marketing_point_values m WHERE m.agency_id = p_agency_id AND m.is_active),
  m_rev AS (
    SELECT l.team_member_id AS tm, 'google_review'::text AS event_key, l.occurred_on AS on_date, l.customer_label AS customer, l.id,
      (SELECT count(*) FROM public.retention_activity_log p
        WHERE p.agency_id = p_agency_id AND p.team_member_id = l.team_member_id AND p.activity_key = 'google_review' AND p.status = 'credited'
          AND p.occurred_on >= v_cycle_start
          AND (p.occurred_on < l.occurred_on OR (p.occurred_on = l.occurred_on AND p.created_at < l.created_at)))::int AS prior
    FROM public.retention_activity_log l
    WHERE l.agency_id = p_agency_id AND l.activity_key = 'google_review' AND l.status = 'credited' AND l.week_end_date = v_week_end
  ),
  m_rq AS (
    SELECT COALESCE(q.sourced_by_team_member_id, q.team_member_id) AS tm, 'referral_quoted'::text AS event_key, q.quote_date AS on_date, q.customer_label AS customer, q.id, 0::int AS prior
    FROM public.quote_log q
    WHERE q.agency_id = p_agency_id AND q.status = 'active' AND q.marketing_source = 'referral' AND q.week_end_date = v_week_end
  ),
  m_rs AS (
    SELECT COALESCE(s.sourced_by_team_member_id, s.team_member_id) AS tm, 'referral_sold'::text AS event_key, s.submitted_date AS on_date, s.customer_label AS customer, s.id,
      (SELECT count(*) FROM public.sales_log p
        WHERE p.agency_id = p_agency_id
          AND COALESCE(p.sourced_by_team_member_id, p.team_member_id) = COALESCE(s.sourced_by_team_member_id, s.team_member_id)
          AND p.status = 'active' AND p.marketing_source = 'referral' AND p.household_status IN ('new', 'winback')
          AND p.submitted_date >= v_cycle_start
          AND (p.submitted_date < s.submitted_date OR (p.submitted_date = s.submitted_date AND p.created_at < s.created_at)))::int AS prior
    FROM public.sales_log s
    WHERE s.agency_id = p_agency_id AND s.status = 'active' AND s.marketing_source = 'referral'
      AND s.household_status IN ('new', 'winback') AND s.week_end_date = v_week_end
  ),
  m_ev AS (SELECT * FROM m_rev UNION ALL SELECT * FROM m_rq UNION ALL SELECT * FROM m_rs),
  m_priced AS (
    SELECT e.tm, e.event_key, e.on_date, e.customer, e.id, e.prior, mv.label,
           ROUND(mv.base_points + mv.step_per_prior * LEAST(mv.prior_cap, e.prior), 2) AS points
    FROM m_ev e JOIN mv ON mv.event_key = e.event_key
  ),
  m_agg AS (
    SELECT tm, SUM(points) AS points,
           jsonb_agg(jsonb_build_object('id', id, 'kind', event_key, 'label', label, 'on_date', on_date, 'customer', customer, 'nth', prior + 1, 'points', points)
                     ORDER BY on_date DESC, customer) AS items
    FROM m_priced GROUP BY tm
  ),
  q_rows AS (
    SELECT q.team_member_id AS tm, q.id, q.quote_date, q.customer_label, q.products_discussed, q.marketing_source, q.relationship_type,
           (SELECT string_agg(COALESCE(pt.label, initcap(qp.line_of_business)), ', ' ORDER BY qp.created_at)
              FROM public.quote_log_products qp
              LEFT JOIN public.product_types pt ON pt.agency_id = qp.agency_id AND pt.line_of_business = qp.line_of_business AND pt.type_key = qp.product_type
             WHERE qp.quote_log_id = q.id) AS types
    FROM public.quote_log q
    WHERE q.agency_id = p_agency_id AND q.status = 'active' AND q.week_end_date = v_week_end
  ),
  q_agg AS (
    SELECT tm, count(*)::int AS n,
           jsonb_agg(jsonb_build_object('id', id, 'on_date', quote_date, 'customer', customer_label, 'products', products_discussed, 'types', types,
                                        'source', marketing_source, 'relationship', relationship_type)
                     ORDER BY quote_date DESC, customer_label) AS items
    FROM q_rows GROUP BY tm
  ),
  prod AS (
    SELECT s.team_member_id AS tm, p.id, s.id AS sale_id, p.line_of_business AS lob, p.product_type, COALESCE(p.issued_premium, p.premium) AS premium,
           GREATEST(1, COALESCE(p.policy_count, 1)) AS policy_count, p.vehicle_count, p.issued_date, s.customer_label, pt.label AS type_label
    FROM public.sales_log s
    JOIN public.sales_log_products p ON p.sales_log_id = s.id
    LEFT JOIN public.product_types pt ON pt.agency_id = s.agency_id AND pt.line_of_business = p.line_of_business AND pt.type_key = p.product_type
    WHERE s.agency_id = p_agency_id AND s.status = 'active' AND p.issued_date IS NOT NULL
      AND p.issued_date BETWEEN v_cycle_start AND v_week_end
  ),
  sp AS (
    SELECT r.id AS tm,
      (SELECT public.compute_sp_from_production(
          COALESCE(SUM(CASE WHEN x.lob = 'auto' THEN x.policy_count END), 0), COALESCE(SUM(CASE WHEN x.lob = 'fire' THEN x.policy_count END), 0),
          COALESCE(SUM(CASE WHEN x.lob = 'life' THEN x.premium END), 0),     COALESCE(SUM(CASE WHEN x.lob = 'health' THEN x.premium END), 0),
          COALESCE(SUM(CASE WHEN x.lob = 'auto' THEN x.premium END), 0),     COALESCE(SUM(CASE WHEN x.lob = 'fire' THEN x.premium END), 0))
         FROM prod x WHERE x.tm = r.id) AS cur,
      (SELECT public.compute_sp_from_production(
          COALESCE(SUM(CASE WHEN x.lob = 'auto' THEN x.policy_count END), 0), COALESCE(SUM(CASE WHEN x.lob = 'fire' THEN x.policy_count END), 0),
          COALESCE(SUM(CASE WHEN x.lob = 'life' THEN x.premium END), 0),     COALESCE(SUM(CASE WHEN x.lob = 'health' THEN x.premium END), 0),
          COALESCE(SUM(CASE WHEN x.lob = 'auto' THEN x.premium END), 0),     COALESCE(SUM(CASE WHEN x.lob = 'fire' THEN x.premium END), 0))
         FROM prod x WHERE x.tm = r.id AND x.issued_date <= v_prev_end) AS prev,
      (SELECT jsonb_agg(jsonb_build_object('id', x.id, 'sale_id', x.sale_id, 'issued_on', x.issued_date, 'customer', x.customer_label, 'line', x.lob,
                                           'type', COALESCE(x.type_label, initcap(x.lob)), 'premium', x.premium, 'policies', x.policy_count, 'vehicles', x.vehicle_count)
                        ORDER BY x.issued_date DESC, x.customer_label)
         FROM prod x WHERE x.tm = r.id AND x.issued_date >= v_week_start) AS items
    FROM roster r
  ),
  rp AS (SELECT * FROM public.compute_weekly_retention_points(p_agency_id, v_week_end)),
  rp_items AS (
    SELECT l.team_member_id AS tm,
           jsonb_agg(jsonb_build_object('id', l.id, 'on_date', l.occurred_on, 'customer', l.customer_label, 'activity_key', l.activity_key,
                                        'label', COALESCE(lb.label, l.activity_key), 'points', l.points, 'source', l.source,
                                        'clears_on', CASE WHEN l.credited_week_end_date <> v_week_end THEN l.credit_available_on END,
                                        'note', COALESCE(CASE WHEN l.save_reason IS NOT NULL THEN initcap(l.save_line) || ': ' || l.save_reason END, l.note))
                     ORDER BY l.occurred_on DESC, l.created_at DESC) AS items
    FROM public.retention_activity_log l LEFT JOIN labels lb ON lb.activity_key = l.activity_key
    WHERE l.agency_id = p_agency_id AND l.status = 'credited' AND (l.week_end_date = v_week_end OR l.credited_week_end_date = v_week_end)
    GROUP BY l.team_member_id
  ),
  conv AS (SELECT * FROM public.rp_week_rollup(v_week_end, NULL)),
  people AS (
    SELECT r.id, r.first_name, r.role_category,
      jsonb_build_object('points', COALESCE(m.points, 0), 'items', COALESCE(m.items, '[]'::jsonb)) AS marketing,
      jsonb_build_object('count', COALESCE(q.n, 0), 'items', COALESCE(q.items, '[]'::jsonb)) AS quotes,
      jsonb_build_object(
        'points', ROUND(COALESCE((s.cur->'commission'->>'total_commission')::numeric, 0) - COALESCE((s.prev->'commission'->>'total_commission')::numeric, 0), 2),
        'qtd_points', COALESCE((s.cur->'commission'->>'total_commission')::numeric, 0),
        'pc_rate', (s.cur->'rates'->>'pc_rate_capped')::numeric, 'lh_rate', (s.cur->'rates'->>'lh_rate_capped')::numeric,
        'items', COALESCE(s.items, '[]'::jsonb)) AS sales,
      jsonb_build_object('hours_in_office', COALESCE(p.hours_in_office, 0), 'hour_points', COALESCE(p.hour_points, 0),
        'calls_answered', COALESCE(p.calls_answered, 0), 'call_points', COALESCE(p.call_points, 0),
        'missed_pct', COALESCE(p.missed_pct, 0), 'reduction_pct', COALESCE(p.reduction_pct, 0),
        'logged_points', COALESCE(p.logged_points, 0), 'derived_points', COALESCE(p.derived_points, 0),
        'gross', COALESCE(p.gross_points, 0), 'net', COALESCE(p.net_points, 0), 'items', COALESCE(ri.items, '[]'::jsonb)) AS retention,
      jsonb_build_object('scorecards', COALESCE(c.scorecards, 0), 'avg', c.scorecard_avg, 'pivots', COALESCE(c.pivots, 0)) AS conversations
    FROM roster r
    LEFT JOIN m_agg m ON m.tm = r.id
    LEFT JOIN q_agg q ON q.tm = r.id
    LEFT JOIN sp s ON s.tm = r.id
    LEFT JOIN rp p ON p.team_member_id = r.id
    LEFT JOIN rp_items ri ON ri.tm = r.id
    LEFT JOIN conv c ON c.team_member_id = r.id
  )
  SELECT jsonb_agg(jsonb_build_object('team_member_id', id, 'first_name', first_name, 'role_category', role_category,
                                      'marketing', marketing, 'quotes', quotes, 'sales', sales, 'retention', retention, 'conversations', conversations)
                   ORDER BY first_name),
         jsonb_build_object(
           'marketing',       COALESCE(SUM((marketing->>'points')::numeric), 0),
           'quotes',          COALESCE(SUM((quotes->>'count')::int), 0),
           'sales',           COALESCE(SUM((sales->>'points')::numeric), 0),
           'retention_net',   COALESCE(SUM((retention->>'net')::numeric), 0),
           'retention_gross', COALESCE(SUM((retention->>'gross')::numeric), 0),
           'missed_pct',      COALESCE(MAX((retention->>'missed_pct')::numeric), 0))
  INTO v_people, v_team
  FROM people;

  RETURN jsonb_build_object('ok', true, 'week_end', v_week_end, 'week_start', v_week_start, 'cycle_start', v_cycle_start,
                            'team', COALESCE(v_team, '{}'::jsonb), 'people', COALESCE(v_people, '[]'::jsonb));
END $$;
