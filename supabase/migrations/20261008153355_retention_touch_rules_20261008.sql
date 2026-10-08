-- Retention points rulings 2026-10-08 (Peter): Claims Touch, onboarding label, review cap,
-- 90-day clawback, clawback exemptions. All points figured on the fly; nothing new is stored
-- except Peter's or Marie's yes/no on an exemption.

-- The new rules start with the week ending 2026-10-10, so weeks already paid never reprice.
INSERT INTO public.settings (agency_id, setting_key, setting_value, setting_type, description)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'retention_touch_rules_from_week_end', '2026-10-10', 'date',
       'First week the 2026-10-08 retention rules apply: Claims Touch cap, Policy Review 5-month cap, onboarding label, 90-day clawback (by the week a cancelation is recorded).'
WHERE NOT EXISTS (SELECT 1 FROM public.settings WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
                    AND setting_key = 'retention_touch_rules_from_week_end');

INSERT INTO public.retention_point_values
  (agency_id, activity_key, label, points, category, requires_note, requires_ecrm, requires_platform, spot_checkable,
   sort_order, is_active, description, prior_step_pct, prior_cap)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'claims_touch', 'Claims Touch', 3.00, 'logged', true, true, false, true,
       82, true,
       'You checked in with a customer about a claim. Pick the policy the claim is on, add the ECRM link and a note on what you covered. Paid up to 3 times per household in any 6 months, however many claims they have. If the policy cancels within 90 days, the points come off.',
       0, 0
WHERE NOT EXISTS (SELECT 1 FROM public.retention_point_values WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
                    AND activity_key = 'claims_touch');

UPDATE public.retention_point_values
   SET description = 'A conversation with the customer about one of their policies. Pick the policy and note what you covered. One paid review per policy every 5 months. A review within 60 days of the sale is onboarding: it pays and does not count toward the 5 months. If the policy cancels within 90 days, the points come off.',
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND activity_key = 'policy_review';

ALTER TABLE public.cancelation_log ADD COLUMN IF NOT EXISTS clawback_exempt_reason text;
ALTER TABLE public.cancelation_log ADD COLUMN IF NOT EXISTS clawback_exempt_decided_by uuid;
ALTER TABLE public.cancelation_log ADD COLUMN IF NOT EXISTS clawback_exempt_decided_at timestamptz;

-- What the note says the cancelation was about. For analysis only; no reason field on the form.
CREATE OR REPLACE FUNCTION public.rp_cancel_cause(p_note text, p_is_replacement boolean DEFAULT false)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp' AS $f$
  SELECT CASE
    WHEN COALESCE(p_is_replacement, false) OR COALESCE(p_note, '') ~* '\m(replac|rewr[io]te|rewritten|rolled into|moved (it )?to (our|another|a new) policy)' THEN 'replaced'
    WHEN COALESCE(p_note, '') ~* '\m(sold|traded|trade[- ]in|totaled|total loss|no longer (own|has|have)|got rid of|repossess)' THEN 'sold item'
    WHEN COALESCE(p_note, '') ~* '\mclaim' THEN 'claim'
    WHEN COALESCE(p_note, '') ~* '\m(moved|moving|relocat|out of state|new state)' THEN 'moved'
    WHEN COALESCE(p_note, '') ~* '\m(price|cheaper|cheap|rate|rates|premium|expensive|afford|cost|went up|increase|quote[sd]? (lower|less)|saving|save money|progressive|geico|allstate|usaa)' THEN 'price'
    WHEN COALESCE(p_note, '') ~* '\m(service|rude|unhappy|frustrat|never (called|answered|heard)|no one|nobody|wait|response|ignored|upset)' THEN 'service'
    ELSE 'none given' END
$f$;

-- What the note suggests about a clawback exemption. Only a guess for the Spot-check; nothing
-- counts until Peter or Marie confirms. Non-pay is never an exemption.
CREATE OR REPLACE FUNCTION public.rp_clawback_exempt_guess(p_note text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp' AS $f$
  SELECT CASE
    WHEN COALESCE(p_note, '') ~* '\m(died|deceased|passed away|death|passed on|estate)' THEN 'death'
    WHEN COALESCE(p_note, '') ~* '\mnon[- ]?pay' THEN NULL
    WHEN COALESCE(p_note, '') ~* '\m(non[- ]?renew|underwrit|company cancel|sf cancel|state farm cancel|carrier cancel)' THEN 'nonrenewal'
    WHEN COALESCE(p_note, '') ~* '\m(joined|added to|moved in with|combined with|merged with|went (on|onto) (her|his|their|parent|spouse))' THEN 'joined_household'
    ELSE NULL END
$f$;

-- Which Policy Reviews and Claims Touches go unpaid under the caps, and which reviews are onboarding.
-- Onboarding = a review on a policy sold 60 days or less before it; it pays and is left out of the cap.
-- Review cap: one paid review per policy in any 5 months. Claims cap: 3 paid per household in any 6 months.
-- Entries before the rules' first week are always paid (they were) but still count toward the caps.
CREATE OR REPLACE FUNCTION public.rp_touch_caps()
RETURNS TABLE(id uuid, is_onboarding boolean, capped boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $f$
  WITH RECURSIVE f AS (
    SELECT s.agency_id, s.setting_value::date AS from_wk FROM public.settings s WHERE s.setting_key = 'retention_touch_rules_from_week_end'
  ),
  base AS (
    SELECT l.id, l.agency_id, l.activity_key, l.occurred_on, l.created_at,
           lower(btrim(COALESCE(public.customer_label(l), ''))) AS hh,
           (public.rp_week_end(l.occurred_on) < COALESCE(f.from_wk, '9999-12-31'::date)) AS before_rules,
           (l.activity_key = 'policy_review' AND EXISTS (
              SELECT 1 FROM public.sales_log s JOIN public.sales_log_products p ON p.sales_log_id = s.id
               WHERE s.agency_id = l.agency_id AND s.status = 'active'
                 AND lower(btrim(COALESCE(public.customer_label(s), ''))) = lower(btrim(COALESCE(public.customer_label(l), '')))
                 AND p.line_of_business = l.policy_line
                 AND COALESCE(p.product_type, '') = COALESCE(l.product_type, '')
                 AND s.submitted_date BETWEEN l.occurred_on - 60 AND l.occurred_on)) AS is_onboarding,
           l.policy_line, l.product_type
    FROM public.retention_activity_log l
    LEFT JOIN f ON f.agency_id = l.agency_id
    WHERE l.activity_key IN ('policy_review', 'claims_touch') AND l.status = 'credited' AND l.points > 0
  ),
  seq AS (
    SELECT b.*,
           CASE WHEN b.activity_key = 'claims_touch' THEN b.hh
                ELSE b.hh || '|' || COALESCE(b.policy_line, '') || '|' || COALESCE(b.product_type, '') END AS grp,
           row_number() OVER (PARTITION BY b.agency_id, b.activity_key,
                                CASE WHEN b.activity_key = 'claims_touch' THEN b.hh
                                     ELSE b.hh || '|' || COALESCE(b.policy_line, '') || '|' || COALESCE(b.product_type, '') END
                              ORDER BY b.occurred_on, b.created_at, b.id) AS rn
    FROM base b
    WHERE NOT b.is_onboarding
  ),
  walk AS (
    SELECT s.agency_id, s.activity_key, s.grp, s.rn, s.id, true AS paid, ARRAY[s.occurred_on] AS paid_on
    FROM seq s WHERE s.rn = 1
    UNION ALL
    SELECT n.agency_id, n.activity_key, n.grp, n.rn, n.id, z.ok,
           CASE WHEN z.ok THEN w.paid_on || n.occurred_on ELSE w.paid_on END
    FROM walk w
    JOIN seq n ON n.agency_id = w.agency_id AND n.activity_key = w.activity_key AND n.grp = w.grp AND n.rn = w.rn + 1
    CROSS JOIN LATERAL (
      SELECT n.before_rules OR CASE
               WHEN n.activity_key = 'claims_touch'
                 THEN (SELECT count(*) FROM unnest(w.paid_on) d WHERE d > (n.occurred_on - interval '6 months')::date) < 3
               ELSE NOT EXISTS (SELECT 1 FROM unnest(w.paid_on) d WHERE d > (n.occurred_on - interval '5 months')::date)
             END AS ok
    ) z
  )
  SELECT b.id, b.is_onboarding, COALESCE(NOT w.paid, false) AS capped
  FROM base b LEFT JOIN walk w ON w.id = b.id;
$f$;

CREATE OR REPLACE VIEW public.retention_activity_now WITH (security_invoker = true) AS
 WITH k AS (SELECT c.id, c.is_onboarding, c.capped FROM public.rp_touch_caps() c),
 x AS (
         SELECT l.id,
            l.agency_id,
            l.team_member_id,
            l.activity_key,
            l.occurred_on,
            l.week_end_date,
            l.credited_week_end_date,
            l.credit_available_on,
            l.customer_first_name,
            l.customer_last_initial,
            customer_label(l.*) AS customer_label,
            l.ecrm_url,
            l.note,
            l.save_reason,
            l.save_line,
            l.points,
            l.status,
            l.source,
            l.source_id,
            l.created_by,
            l.created_at,
            l.updated_at,
            l.voided_at,
            l.voided_by,
            l.void_reason,
            l.verified_at,
            l.verified_by,
            l.policy_line,
            l.product_type,
            l.premium,
            l.phone_last4,
            l.review_platform,
            l.spot_check_note,
            l.customer_kind,
            v.prior_step_pct,
            v.prior_cap,
            v.prior_step_pct_before,
            v.prior_cap_before,
            v.kicker_from_week_end,
            COALESCE(k.is_onboarding, false) AS is_onboarding,
            COALESCE(k.capped, false) AS capped,
            COALESCE(l.credited_week_end_date, l.week_end_date) AS wk,
            count(*) FILTER (WHERE (l.status <> ALL (ARRAY['void'::text, 'voided'::text])) AND l.points > 0::numeric AND NOT COALESCE(k.capped, false)) OVER (PARTITION BY l.agency_id, l.team_member_id, l.activity_key, (rp_kicker_bucket(v.kicker_from_week_end, COALESCE(l.credited_week_end_date, l.week_end_date), l.occurred_on, a.d)) ORDER BY l.occurred_on, l.created_at, l.id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prior
           FROM retention_activity_log l
             LEFT JOIN retention_point_values v ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
             LEFT JOIN k ON k.id = l.id
             LEFT JOIN LATERAL ( SELECT s.setting_value::date AS d
                   FROM settings s
                  WHERE s.agency_id = l.agency_id AND s.setting_key = 'cycle_anchor_date'::text) a ON true
        )
 SELECT id,
    agency_id,
    team_member_id,
    activity_key,
    occurred_on,
    week_end_date,
    credited_week_end_date,
    credit_available_on,
    customer_first_name,
    customer_last_initial,
    customer_label,
    ecrm_url,
    note,
    save_reason,
    save_line,
    CASE WHEN capped THEN 0::numeric
         ELSE rp_kicked_points(points, prior_step_pct, prior_cap, prior_step_pct_before, prior_cap_before, kicker_from_week_end, wk, prior) END AS points,
    status,
    source,
    source_id,
    created_by,
    created_at,
    updated_at,
    voided_at,
    voided_by,
    void_reason,
    verified_at,
    verified_by,
    policy_line,
    product_type,
    premium,
    phone_last4,
    review_platform,
    spot_check_note,
    customer_kind,
    points AS base_points,
    is_onboarding,
    capped
   FROM x;

-- Every Policy Review / Claims Touch whose reviewed policy canceled within 90 days, by the week the
-- cancelation was recorded. applies = false when it is exempt: a replacement by our own policy, or an
-- exemption Peter or Marie confirmed (death, State Farm nonrenewal, joined another household we insure).
-- A voided or reinstated cancelation drops out, so the points come back on their own.
CREATE OR REPLACE FUNCTION public.rp_touch_clawbacks(p_agency_id uuid, p_week_end date DEFAULT NULL)
RETURNS TABLE(touch_id uuid, team_member_id uuid, activity_key text, touch_on date, customer_label text,
              policy_line text, product_type text, points numeric, cancelation_id uuid, canceled_on date,
              recorded_week_end date, is_replacement boolean, exempt_guess text, exempt_reason text,
              exempt_decided boolean, applies boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $f$
  WITH f AS (SELECT COALESCE((SELECT s.setting_value::date FROM public.settings s
                               WHERE s.agency_id = p_agency_id AND s.setting_key = 'retention_touch_rules_from_week_end'),
                             '9999-12-31'::date) AS from_wk),
  m AS (
    SELECT DISTINCT ON (t.id)
           t.id AS touch_id, t.team_member_id, t.activity_key, t.occurred_on AS touch_on, t.customer_label,
           t.policy_line, t.product_type, t.points, c.id AS cancelation_id, c.canceled_on,
           public.rp_week_end((c.created_at AT TIME ZONE 'America/Chicago')::date) AS recorded_week_end,
           COALESCE(c.is_replacement, false) AS is_replacement,
           public.rp_clawback_exempt_guess(c.note) AS exempt_guess,
           c.clawback_exempt_reason AS exempt_reason,
           (c.clawback_exempt_decided_at IS NOT NULL) AS exempt_decided
    FROM public.retention_activity_now t
    JOIN public.cancelation_log c
      ON c.agency_id = t.agency_id AND c.status = 'active' AND c.reinstated_on IS NULL
     AND lower(btrim(COALESCE(public.customer_label(c), ''))) = lower(btrim(COALESCE(t.customer_label, '')))
     AND c.policy_line = t.policy_line
     AND COALESCE(c.product_type, '') = COALESCE(t.product_type, '')
     AND (t.phone_last4 IS NULL OR c.phone_last4 IS NULL OR c.phone_last4 = t.phone_last4)
     AND c.canceled_on BETWEEN t.occurred_on AND t.occurred_on + 90
    WHERE t.agency_id = p_agency_id AND t.activity_key IN ('policy_review', 'claims_touch')
      AND t.status = 'credited' AND t.points > 0
    ORDER BY t.id, c.created_at, c.id
  )
  SELECT m.touch_id, m.team_member_id, m.activity_key, m.touch_on, m.customer_label, m.policy_line, m.product_type,
         m.points, m.cancelation_id, m.canceled_on, m.recorded_week_end, m.is_replacement, m.exempt_guess,
         m.exempt_reason, m.exempt_decided,
         NOT m.is_replacement AND NOT (m.exempt_decided AND m.exempt_reason IN ('death', 'nonrenewal', 'joined_household')) AS applies
  FROM m, f
  WHERE m.recorded_week_end >= f.from_wk
    AND (p_week_end IS NULL OR m.recorded_week_end = public.rp_week_end(p_week_end));
$f$;
REVOKE ALL ON FUNCTION public.rp_touch_clawbacks(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_touch_clawbacks(uuid, date) TO authenticated, service_role;

-- Spot-check list: cancelations whose note reads like an exemption, with points at stake, not yet decided.
CREATE OR REPLACE FUNCTION public.rp_clawback_exempt_review()
RETURNS TABLE(cancelation_id uuid, customer_label text, policy_line text, product_type text, canceled_on date,
              logged_by text, note text, ecrm_url text, exempt_guess text, points_at_stake numeric, touches jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $f$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'only Peter or Marie can confirm a clawback exemption' USING ERRCODE = '42501'; END IF;
  RETURN QUERY
  SELECT c.id, public.customer_label(c), c.policy_line, c.product_type, c.canceled_on,
         (SELECT t.first_name FROM public.team t WHERE t.id = c.team_member_id), c.note, c.ecrm_url,
         public.rp_clawback_exempt_guess(c.note),
         SUM(w.points),
         jsonb_agg(jsonb_build_object('activity_key', w.activity_key, 'touch_on', w.touch_on, 'points', w.points,
                                      'who', (SELECT t.first_name FROM public.team t WHERE t.id = w.team_member_id))
                   ORDER BY w.touch_on)
  FROM public.cancelation_log c
  JOIN public.rp_touch_clawbacks(a.agency_id, NULL) w ON w.cancelation_id = c.id AND NOT w.is_replacement
  WHERE c.agency_id = a.agency_id AND c.clawback_exempt_decided_at IS NULL
    AND public.rp_clawback_exempt_guess(c.note) IS NOT NULL
  GROUP BY c.id
  ORDER BY c.canceled_on DESC;
END $f$;

-- Peter's or Marie's call: death, nonrenewal or joined_household stops the clawback; none keeps it.
CREATE OR REPLACE FUNCTION public.rp_clawback_exempt_decide(p_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $f$
DECLARE a RECORD; n integer;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'only Peter or Marie can confirm a clawback exemption' USING ERRCODE = '42501'; END IF;
  IF p_reason IS NULL OR p_reason NOT IN ('death', 'nonrenewal', 'joined_household', 'none') THEN
    RAISE EXCEPTION 'pick death, State Farm nonrenewal, joined another household, or not exempt';
  END IF;
  UPDATE public.cancelation_log
     SET clawback_exempt_reason = p_reason, clawback_exempt_decided_by = a.actor_id,
         clawback_exempt_decided_at = now(), updated_at = now()
   WHERE id = p_id AND agency_id = a.agency_id;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RAISE EXCEPTION 'that cancelation is not on file any more'; END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_id, 'reason', p_reason);
END $f$;

CREATE OR REPLACE FUNCTION public.rp_log_activity(p_items jsonb, p_customer_first text, p_customer_last_initial text, p_occurred_on date DEFAULT NULL::date, p_ecrm_url text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_team_member_id uuid DEFAULT NULL::uuid, p_customer_kind text DEFAULT 'person'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; item jsonb; v RECORD;
  v_today date := public.rp_today_central();
  v_on date; v_label text; v_key text; v_reason text; v_line text; v_type text;
  v_credit_on date; v_credit_week date; v_id uuid; v_pl text;
  v_created jsonb := '[]'::jsonb; v_total numeric := 0; v_note text; v_url text;
  v_kind text := public.rp_customer_kind(p_customer_kind);
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(p_team_member_id);
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'check at least one thing you did';
  END IF;
  v_on := COALESCE(p_occurred_on, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'date cannot be in the future'; END IF;
  IF v_on < v_today - 7 THEN RAISE EXCEPTION 'log within 7 days of when it happened'; END IF;
  v_label := public.rp_customer_label(p_customer_first, p_customer_last_initial, v_kind);
  v_note := NULLIF(btrim(COALESCE(p_note,'')), '');
  v_url  := NULLIF(btrim(COALESCE(p_ecrm_url,'')), '');
  IF v_url IS NOT NULL AND v_url !~* '^https?://' THEN RAISE EXCEPTION 'ECRM link must start with http'; END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_key := item->>'activity_key';
    SELECT * INTO v FROM public.retention_point_values
    WHERE agency_id = a.agency_id AND activity_key = v_key AND is_active AND category = 'logged';
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown or not-loggable item: %', v_key; END IF;
    IF v.requires_note AND v_note IS NULL AND NULLIF(btrim(COALESCE(item->>'save_reason','')),'') IS NULL THEN
      RAISE EXCEPTION '% needs a note on what you covered / the reason', v.label;
    END IF;
    IF v.requires_ecrm AND v_url IS NULL THEN
      RAISE EXCEPTION '% needs the ECRM link so it can be checked', v.label;
    END IF;
    IF v.requires_platform AND NULLIF(btrim(COALESCE(item->>'review_platform','')), '') IS NULL THEN
      RAISE EXCEPTION '% needs the site it was left on: Google, Facebook or Yelp', v.label;
    END IF;
    IF NULLIF(btrim(COALESCE(item->>'review_platform','')), '') IS NOT NULL
       AND lower(btrim(item->>'review_platform')) NOT IN ('google', 'facebook', 'yelp') THEN
      RAISE EXCEPTION 'the review site has to be Google, Facebook or Yelp';
    END IF;
    -- Peter 2026-10-03: a pivot names the line it pivoted to; a policy review names
    -- the policy reviewed (its line, and its type wherever the line has types).
    -- Peter 2026-10-08: a Claims Touch names the policy the claim is on, like a review.
    -- Peter 2026-10-05: authorized team do not log a pivot. Quoting an existing customer writes it
    -- (rp_derive_quote_pivot). The Pivot activity is for team who are not authorized.
    IF v_key = 'pivot' AND public.team_can_quote(a.team_member_id) THEN
      RAISE EXCEPTION 'authorized team log the quote instead. Quoting an existing customer counts as the pivot';
    END IF;
    IF v_key IN ('pivot', 'policy_review', 'claims_touch') THEN
      v_pl := NULLIF(lower(btrim(COALESCE(item->>'policy_line',''))), '');
      -- Peter 2026-10-07: a pivot can be Generic, for a hand-off that names no product.
      IF v_pl IS NULL OR v_pl NOT IN ('auto','fire','life','health','variable','bank') AND NOT (v_key = 'pivot' AND v_pl = 'generic') THEN
        RAISE EXCEPTION '%', CASE WHEN v_key = 'pivot' THEN 'pick the product they pivoted to'
                                  WHEN v_key = 'claims_touch' THEN 'pick the policy the claim is on'
                                  ELSE 'pick the policy reviewed' END;
      END IF;
      -- Peter 2026-10-05: a pivot names the product it pivoted to as well as the line.
      IF NULLIF(btrim(COALESCE(item->>'product_type','')), '') IS NULL
         AND EXISTS (SELECT 1 FROM public.product_types pt
                      WHERE pt.agency_id = a.agency_id AND pt.line_of_business = v_pl AND pt.is_active) THEN
        RAISE EXCEPTION '%', CASE WHEN v_key = 'pivot' THEN 'pick the product they pivoted to'
                                  WHEN v_key = 'claims_touch' THEN 'pick the policy the claim is on'
                                  ELSE 'pick the policy reviewed' END;
      END IF;
    END IF;
    -- Peter 2026-09-15: a save is credited per POLICY, so several saves for the
    -- same household on the same day are normal. Same reason autopay is exempt.
    IF v_key NOT IN ('autopay_enrollment', 'cancelation_saved') AND EXISTS (SELECT 1 FROM public.retention_activity_log l
               WHERE l.agency_id = a.agency_id AND l.team_member_id = a.team_member_id
                 AND l.activity_key = v_key AND l.customer_label = v_label AND l.occurred_on = v_on
                 AND l.status = 'credited' AND l.created_at < now()) THEN
      RAISE EXCEPTION '% for % is already logged for %. Use Undo or remove the first one if that was a mistake.',
        v.label, v_label, CASE WHEN v_on = v_today THEN 'today' ELSE to_char(v_on, 'Mon FMDD') END;
    END IF;

    v_credit_on := NULL; v_credit_week := public.rp_week_end(v_on); v_reason := NULL; v_line := NULL; v_type := NULL;
    IF v_key = 'cancelation_saved' THEN
      IF v_on <> v_today THEN RAISE EXCEPTION 'a save is logged the same day the request or notice comes in'; END IF;
      v_reason := NULLIF(btrim(COALESCE(item->>'save_reason','')), '');
      v_line   := NULLIF(lower(btrim(COALESCE(item->>'save_line',''))), '');
      v_type   := NULLIF(btrim(COALESCE(item->>'product_type','')), '');
      IF v_reason IS NULL THEN RAISE EXCEPTION 'a save needs the reason the customer gave'; END IF;
      IF v_line IS NULL OR v_line NOT IN ('auto','fire','life','health','variable','bank') THEN
        RAISE EXCEPTION 'a save needs the policy line that was at risk';
      END IF;
      -- The unit is one policy. Line alone cannot tell two auto policies in the
      -- same household apart, so the type is required wherever the line has types.
      IF v_type IS NULL AND EXISTS (SELECT 1 FROM public.product_types pt
                                     WHERE pt.agency_id = a.agency_id AND pt.line_of_business = v_line) THEN
        RAISE EXCEPTION 'a save needs the policy type that was at risk';
      END IF;
      IF EXISTS (SELECT 1 FROM public.retention_activity_log l
                 WHERE l.agency_id = a.agency_id AND l.activity_key = 'cancelation_saved' AND l.status = 'credited'
                   AND l.customer_label = v_label AND l.save_line = v_line
                   AND COALESCE(l.product_type, '') = COALESCE(v_type, '')
                   AND l.occurred_on > v_on - 90) THEN
        RAISE EXCEPTION 'one save per policy per ninety days — % already has a % save on file', v_label, COALESCE(v_type, v_line);
      END IF;
      v_credit_on := v_on + 30;
      v_credit_week := public.rp_week_end(v_credit_on);
    END IF;

    INSERT INTO public.retention_activity_log
      (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date, credit_available_on,
       customer_first_name, customer_last_initial, customer_kind, ecrm_url, note, save_reason, save_line, points, source, created_by, policy_line, product_type, premium, review_platform)
    VALUES
      (a.agency_id, a.team_member_id, v_key, v_on, public.rp_week_end(v_on), v_credit_week, v_credit_on,
       btrim(p_customer_first), public.rp_customer_initial(p_customer_last_initial, v_kind), v_kind, v_url, v_note, v_reason, v_line, v.points, 'manual', a.actor_id,
       NULLIF(lower(btrim(COALESCE(item->>'policy_line',''))), ''), NULLIF(btrim(COALESCE(item->>'product_type','')), ''), NULLIF(item->>'premium','')::numeric, NULLIF(lower(btrim(COALESCE(item->>'review_platform',''))), ''))
    RETURNING id INTO v_id;
    v_total := v_total + v.points;
    v_created := v_created || jsonb_build_object('id', v_id, 'activity_key', v_key, 'label', v.label, 'points', v.points,
                                                 'credit_available_on', v_credit_on, 'credited_week_end_date', v_credit_week);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'customer', v_label, 'team_member_id', a.team_member_id,
                            'items', v_created, 'points_total', v_total);
END $function$;

CREATE OR REPLACE FUNCTION public.compute_weekly_retention_points(p_agency_id uuid, p_week_end_date date)
 RETURNS TABLE(team_member_id uuid, first_name text, role_category text, hours_in_office numeric, hour_points numeric, calls_answered integer, call_points numeric, missed_calls integer, missed_pct numeric, reduction_pct numeric, logged_points numeric, derived_points numeric, gross_points numeric, net_points numeric, detail jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- DESIGN RECORD (2026-08-31).
--
-- A missed call is an inbound call nobody picked up: the caller hung up (abandoned) or
-- left a message (voicemail). Same definition the Telegram daily block uses.
--
-- The eGain "Extension Activity" report puts both on the "Not Applicable" (main line) row
-- because the system rings the whole group -- per-desk abandons and voicemails are always
-- 0. So the miss belongs to the team: the team's weekly missed % is applied to every
-- roster member who worked that week (any in-office hours or any answered call). No hours
-- and no calls = no reduction.
--
-- Known limitation: the report is daily totals with no time of day, so a voicemail left
-- after hours counts the same as one left while the phones were open. Week ending
-- 2026-08-01 took 51 voicemails (27 in one day) and lands at 38% missed.
--
-- Reduction curve: 0.04 x missed%^2, capped at 100 (handbook "Missed Calls Shrink Both").
DECLARE
  v_week_end date := public.rp_week_end(p_week_end_date);
  v_week_start date := public.rp_week_end(p_week_end_date) - 6;
  v_hour_val numeric; v_call_val numeric;
  v_team_answered integer := 0;
  v_team_missed integer := 0;
  v_team_abandoned integer := 0;
  v_team_voicemail integer := 0;
  v_team_missed_pct numeric := 0;
BEGIN
  PERFORM public.require_login('staff');
  -- A value change can start on a set week (points_from_week_end); weeks before it keep prior_points,
  -- so a new rate never reprices weeks already paid (calls and hours to $0.60 from Q4 2026).
  SELECT CASE WHEN points_from_week_end IS NOT NULL AND public.rp_week_end(p_week_end_date) < points_from_week_end
              THEN COALESCE(prior_points, points) ELSE points END
    INTO v_hour_val FROM public.retention_point_values WHERE agency_id=p_agency_id AND activity_key='hour_in_office' AND is_active;
  SELECT CASE WHEN points_from_week_end IS NOT NULL AND public.rp_week_end(p_week_end_date) < points_from_week_end
              THEN COALESCE(prior_points, points) ELSE points END
    INTO v_call_val FROM public.retention_point_values WHERE agency_id=p_agency_id AND activity_key='call_answered' AND is_active;
  v_hour_val := COALESCE(v_hour_val, 0); v_call_val := COALESCE(v_call_val, 0);

  SELECT COALESCE(SUM(CASE WHEN d.team_member_id IS NOT NULL
                           THEN COALESCE(d.answered_calls_external,0) + COALESCE(d.transferred_calls_external,0)
                           ELSE 0 END),0)::integer,
         COALESCE(SUM(COALESCE(d.abandoned_calls_external,0)),0)::integer,
         COALESCE(SUM(COALESCE(d.voicemail_calls_external,0)),0)::integer
    INTO v_team_answered, v_team_abandoned, v_team_voicemail
  FROM public.daily_call_activity d
  WHERE d.agency_id = p_agency_id
    AND d.activity_date BETWEEN v_week_start AND v_week_end;

  v_team_missed := v_team_abandoned + v_team_voicemail;
  v_team_missed_pct := CASE WHEN v_team_answered + v_team_missed > 0
                            THEN ROUND(100.0 * v_team_missed / (v_team_answered + v_team_missed), 2)
                            ELSE 0 END;

  RETURN QUERY
  WITH roster AS (
    SELECT t.id, t.first_name, t.role_category
    FROM public.team t
    WHERE t.agency_id = p_agency_id AND t.is_active AND t.archived_at IS NULL
      AND COALESCE(t.is_test_user,false) = false AND COALESCE(t.is_admin_backoffice,false) = false
      AND (t.role_level IS NULL OR t.role_level <> 'Owner') AND t.category = 'agency'
      AND (t.end_date IS NULL OR t.end_date >= v_week_start)
  ),
  hrs AS (
    SELECT h.team_member_id AS tm, COALESCE(SUM(CASE WHEN h.location = 'in_office' THEN h.hours ELSE 0 END),0)::numeric AS in_office
    FROM public.get_weekly_cpr_hours(p_agency_id, v_week_end) h
    GROUP BY h.team_member_id
  ),
  calls AS (
    SELECT d.team_member_id AS tm,
           COALESCE(SUM(d.answered_calls_external),0) + COALESCE(SUM(d.transferred_calls_external),0) AS answered
    FROM public.daily_call_activity d
    WHERE d.agency_id = p_agency_id AND d.team_member_id IS NOT NULL
      AND d.activity_date BETWEEN v_week_start AND v_week_end
    GROUP BY d.team_member_id
  ),
  logged AS (
    SELECT l.team_member_id AS tm,
           COALESCE(SUM(CASE WHEN l.source = 'manual' THEN l.points ELSE 0 END),0) AS logged_pts,
           COALESCE(SUM(CASE WHEN l.source <> 'manual' THEN l.points ELSE 0 END),0) AS derived_pts,
           jsonb_object_agg(l.activity_key, l.cnt) FILTER (WHERE l.activity_key IS NOT NULL) AS by_key
    FROM (
      SELECT x.team_member_id, x.activity_key, x.source, SUM(x.points) AS points, COUNT(*) AS cnt
      FROM public.retention_activity_now x
      WHERE x.agency_id = p_agency_id AND x.status = 'credited' AND x.credited_week_end_date = v_week_end
      GROUP BY x.team_member_id, x.activity_key, x.source
    ) l
    GROUP BY l.team_member_id
  ),
  -- Peter 2026-10-08: a Policy Review (onboarding too) or Claims Touch whose policy cancels within 90 days
  -- comes off in the week the cancelation is RECORDED. Figured here every time, never stored.
  claw AS (
    SELECT c.team_member_id AS tm, SUM(c.points) AS pts,
           jsonb_agg(jsonb_build_object('touch_id', c.touch_id, 'activity_key', c.activity_key, 'touch_on', c.touch_on,
                                        'customer', c.customer_label, 'policy_line', c.policy_line, 'product_type', c.product_type,
                                        'canceled_on', c.canceled_on, 'cancelation_id', c.cancelation_id, 'points', c.points)
                     ORDER BY c.touch_on) AS items
    FROM public.rp_touch_clawbacks(p_agency_id, v_week_end) c
    WHERE c.applies
    GROUP BY c.team_member_id
  ),
  calc AS (
    SELECT r.id, r.first_name, r.role_category,
           ROUND(COALESCE(h.in_office,0), 2) AS hours_in_office,
           ROUND(COALESCE(h.in_office,0) * v_hour_val, 2) AS hour_points,
           COALESCE(c.answered,0)::int AS calls_answered,
           ROUND(COALESCE(c.answered,0) * v_call_val, 2) AS call_points,
           (COALESCE(h.in_office,0) > 0 OR COALESCE(c.answered,0) > 0) AS worked,
           COALESCE(lg.logged_pts,0) AS logged_points,
           COALESCE(lg.derived_pts,0) - COALESCE(cw.pts,0) AS derived_points,
           COALESCE(cw.pts,0) AS clawback_pts,
           COALESCE(cw.items,'[]'::jsonb) AS clawbacks,
           COALESCE(lg.by_key,'{}'::jsonb) AS by_key
    FROM roster r
    LEFT JOIN hrs h ON h.tm = r.id
    LEFT JOIN calls c ON c.tm = r.id
    LEFT JOIN logged lg ON lg.tm = r.id
    LEFT JOIN claw cw ON cw.tm = r.id
  ),
  red AS (
    SELECT k.*,
           CASE WHEN k.worked THEN v_team_missed ELSE 0 END AS missed_calls,
           CASE WHEN k.worked THEN v_team_missed_pct ELSE 0 END AS missed_pct,
           CASE WHEN k.worked THEN LEAST(100, ROUND(0.04 * v_team_missed_pct * v_team_missed_pct, 2)) ELSE 0 END AS reduction_pct,
           (k.hour_points + k.call_points + k.logged_points + k.derived_points) AS gross
    FROM calc k
  )
  SELECT k.id, k.first_name, k.role_category,
         k.hours_in_office, k.hour_points, k.calls_answered, k.call_points,
         k.missed_calls::integer, k.missed_pct, k.reduction_pct,
         k.logged_points, k.derived_points,
         ROUND(k.gross, 2) AS gross_points,
         ROUND(k.gross * (1 - k.reduction_pct/100.0), 2) AS net_points,
         jsonb_build_object(
           'week_end_date', v_week_end,
           'values', jsonb_build_object('hour_in_office', v_hour_val, 'call_answered', v_call_val),
           'counts_by_key', k.by_key,
           'clawback_points', k.clawback_pts,
           'clawbacks', k.clawbacks,
           'worked_this_week', k.worked,
           'team_calls_answered', v_team_answered,
           'team_missed_calls', v_team_missed,
           'team_abandoned_calls', v_team_abandoned,
           'team_voicemail_calls', v_team_voicemail,
           'team_missed_pct', v_team_missed_pct,
           'formula', 'net = (hour_pts + call_pts + logged + derived) x (1 - 0.04 x missed%^2 / 100); derived already has 90-day review and claims-touch clawbacks taken off; missed% = team abandoned + voicemail calls / (team answered + those), applied to everyone who worked the week'
         ) AS detail
  FROM red k
  ORDER BY k.first_name;
END $function$;

