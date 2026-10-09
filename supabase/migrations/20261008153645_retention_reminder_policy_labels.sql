-- Retention morning reminders: name the policy by its label (Private Passenger, Home), not its key.
CREATE OR REPLACE FUNCTION public.rp_retention_miss_lines(p_agency_id uuid, p_on date DEFAULT NULL)
RETURNS TABLE(team_member_id uuid, first_name text, email text, line_key text, line_text text, sort_on date)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $f$
  WITH d AS (
    SELECT COALESCE(p_on, public.rp_today_central()) AS today,
           COALESCE(p_on, public.rp_today_central()) - CASE extract(isodow FROM COALESCE(p_on, public.rp_today_central()))::int
                                                         WHEN 1 THEN 3 WHEN 7 THEN 2 ELSE 1 END AS prev_workday,
           public.rp_week_end(COALESCE(p_on, public.rp_today_central())) AS wk
  ),
  people AS (
    SELECT t.id, t.first_name, COALESCE(NULLIF(btrim(t.email_sf), ''), NULLIF(btrim(t.email_personal), '')) AS email, t.role_category
    FROM public.team t
    WHERE t.agency_id = p_agency_id AND t.is_active AND t.archived_at IS NULL AND t.category = 'agency'
      AND COALESCE(t.is_test_user, false) = false AND (t.role_level IS NULL OR t.role_level <> 'Owner')
  ),
  m_save AS (
    SELECT c.team_member_id AS tm, 'no_save_before_cancel'::text AS k,
           public.customer_label(c) || ' ' || COALESCE((SELECT pt.label FROM public.product_types pt WHERE pt.agency_id = c.agency_id AND pt.line_of_business = c.policy_line AND pt.type_key = c.product_type LIMIT 1), c.product_type, c.policy_line) || ' canceled ' || to_char(c.canceled_on, 'Mon FMDD')
             || ' with no Cancelation Saved logged before it. Log the save attempt the day the request or notice comes in.' AS txt,
           c.canceled_on AS on_d
    FROM public.cancelation_log c, d
    WHERE c.agency_id = p_agency_id AND c.status = 'active' AND NOT COALESCE(c.is_replacement, false)
      AND COALESCE(c.entry_source, 'manual') <> 'historical_backfill'
      AND (c.created_at AT TIME ZONE 'America/Chicago')::date BETWEEN d.prev_workday AND d.today - 1
      AND NOT EXISTS (SELECT 1 FROM public.retention_activity_log s
                       WHERE s.agency_id = c.agency_id AND s.activity_key = 'cancelation_saved'
                         AND lower(btrim(COALESCE(public.customer_label(s), ''))) = lower(btrim(COALESCE(public.customer_label(c), '')))
                         AND s.save_line = c.policy_line AND COALESCE(s.product_type, '') = COALESCE(c.product_type, '')
                         AND s.occurred_on BETWEEN c.canceled_on - 90 AND c.canceled_on)
  ),
  cpr AS (
    SELECT r.week_ending_date, COALESCE(r.new_claims, 0) AS new_claims
    FROM public.weekly_cpr_reports r, d
    WHERE r.agency_id = p_agency_id AND r.week_ending_date < d.wk
    ORDER BY r.week_ending_date DESC LIMIT 1
  ),
  touched AS (
    SELECT count(*) AS n FROM public.retention_activity_log l, cpr
    WHERE l.agency_id = p_agency_id AND l.activity_key = 'claims_touch' AND l.status = 'credited'
      AND l.occurred_on > cpr.week_ending_date - 7
  ),
  m_claims AS (
    SELECT p.id AS tm, 'claims_no_touch'::text AS k,
           'Last week''s CPR shows ' || cpr.new_claims || ' new claim' || CASE WHEN cpr.new_claims = 1 THEN '' ELSE 's' END
             || '. ' || touched.n || ' Claims Touch' || CASE WHEN touched.n = 1 THEN '' ELSE 'es' END
             || ' logged since. Call the rest and log a Claims Touch for each.' AS txt,
           cpr.week_ending_date AS on_d
    FROM cpr, touched, people p
    WHERE cpr.new_claims > touched.n AND p.role_category = 'Retention'
  ),
  m_autopay AS (
    SELECT s.team_member_id AS tm, 'sale_no_autopay'::text AS k,
           public.customer_label(s) || ' ' || COALESCE((SELECT pt.label FROM public.product_types pt WHERE pt.agency_id = s.agency_id AND pt.line_of_business = sp.line_of_business AND pt.type_key = sp.product_type LIMIT 1), sp.product_type, sp.line_of_business) || ' sold ' || to_char(s.submitted_date, 'Mon FMDD')
             || ': Autopay is not ticked. Set it up and tick it on the sale.' AS txt,
           s.submitted_date AS on_d
    FROM public.sales_log s JOIN public.sales_log_products sp ON sp.sales_log_id = s.id, d
    WHERE s.agency_id = p_agency_id AND s.status = 'active' AND NOT COALESCE(sp.autopay_enrolled, false)
      AND sp.line_of_business IN ('auto', 'fire')
      AND s.submitted_date BETWEEN d.today - 30 AND d.today - 1
      AND s.submitted_date >= (SELECT st.setting_value::date - 6 FROM public.settings st
                                WHERE st.agency_id = p_agency_id AND st.setting_key = 'retention_touch_rules_from_week_end')
  ),
  ev AS (
    SELECT e.tm, e.event_key, count(*) AS n
    FROM d, public.marketing_events_priced(p_agency_id, d.wk - 6, d.wk) e
    WHERE e.wk = d.wk AND e.event_key IN ('google_review', 'referral_quoted')
    GROUP BY e.tm, e.event_key
  ),
  m_weekly AS (
    SELECT p.id AS tm, 'weekly_reviews'::text AS k,
           'Online reviews this week: ' || COALESCE(r.n, 0) || ' of 5.' AS txt, d.wk AS on_d
    FROM people p CROSS JOIN d LEFT JOIN ev r ON r.tm = p.id AND r.event_key = 'google_review'
    WHERE p.role_category = 'Retention' AND COALESCE(r.n, 0) < 5
    UNION ALL
    SELECT p.id, 'weekly_referrals', 'Referrals quoted this week: ' || COALESCE(r.n, 0) || ' of 2.', d.wk
    FROM people p CROSS JOIN d LEFT JOIN ev r ON r.tm = p.id AND r.event_key = 'referral_quoted'
    WHERE p.role_category = 'Retention' AND COALESCE(r.n, 0) < 2
  ),
  allm AS (
    SELECT * FROM m_save UNION ALL SELECT * FROM m_claims UNION ALL SELECT * FROM m_autopay UNION ALL SELECT * FROM m_weekly
  )
  SELECT p.id, p.first_name, p.email, m.k, m.txt, m.on_d
  FROM allm m JOIN people p ON p.id = m.tm
  ORDER BY p.first_name, array_position(ARRAY['no_save_before_cancel','claims_no_touch','sale_no_autopay','weekly_reviews','weekly_referrals'], m.k), m.on_d;
$f$;

