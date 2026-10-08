-- Retention rulings 2026-10-08 (Peter), part 2: cancelation lookback for History, and the
-- weekday-morning reminder email (one line per miss, only to the person missing it).

-- Each cancelation: who sold it, every touch on the household since, and the cause read from the note.
CREATE OR REPLACE FUNCTION public.rp_cancel_lookback(p_from date, p_to date)
RETURNS TABLE(cancelation_id uuid, canceled_on date, recorded_on date, customer_label text, policy_line text,
              product_type text, premium numeric, logged_by text, note text, ecrm_url text, cause text,
              is_replacement boolean, sold_by text, sold_on date, clawback_points numeric, touches jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $f$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'only Peter or Marie can see the cancelation lookback' USING ERRCODE = '42501'; END IF;
  RETURN QUERY
  WITH c AS (
    SELECT cl.*, lower(btrim(COALESCE(public.customer_label(cl), ''))) AS hh, public.customer_label(cl) AS lbl
    FROM public.cancelation_log cl
    WHERE cl.agency_id = a.agency_id AND cl.status = 'active' AND cl.canceled_on BETWEEN p_from AND p_to
  ),
  sale AS (
    SELECT DISTINCT ON (c.id) c.id AS cid, s.team_member_id AS seller, s.submitted_date
    FROM c
    JOIN public.sales_log_products p ON (c.matched_sale_product_id IS NOT NULL AND p.id = c.matched_sale_product_id)
                                     OR (c.matched_sale_product_id IS NULL AND p.line_of_business = c.policy_line
                                         AND COALESCE(p.product_type, '') = COALESCE(c.product_type, ''))
    JOIN public.sales_log s ON s.id = p.sales_log_id AND s.agency_id = c.agency_id AND s.status = 'active'
     AND (c.matched_sale_product_id IS NOT NULL OR lower(btrim(COALESCE(public.customer_label(s), ''))) = c.hh)
     AND s.submitted_date <= c.canceled_on
    ORDER BY c.id, s.submitted_date DESC, s.created_at DESC
  ),
  claw AS (
    SELECT w.cancelation_id AS cid, SUM(w.points) AS pts
    FROM public.rp_touch_clawbacks(a.agency_id, NULL) w WHERE w.applies GROUP BY w.cancelation_id
  )
  SELECT c.id, c.canceled_on, (c.created_at AT TIME ZONE 'America/Chicago')::date, c.lbl, c.policy_line, c.product_type,
         c.premium, (SELECT t.first_name FROM public.team t WHERE t.id = c.team_member_id), c.note, c.ecrm_url,
         public.rp_cancel_cause(c.note, c.is_replacement), COALESCE(c.is_replacement, false),
         (SELECT t.first_name FROM public.team t WHERE t.id = sl.seller), sl.submitted_date,
         COALESCE(cw.pts, 0),
         COALESCE((
           SELECT jsonb_agg(jsonb_build_object(
                    'on', r.occurred_on, 'activity_key', r.activity_key,
                    'label', COALESCE(v.label, r.activity_key) || CASE WHEN r.is_onboarding THEN ' (onboarding)' ELSE '' END,
                    'who', (SELECT t.first_name FROM public.team t WHERE t.id = r.team_member_id),
                    'points', r.points, 'this_policy', (r.policy_line = c.policy_line AND COALESCE(r.product_type, '') = COALESCE(c.product_type, '')
                                                          OR (r.save_line = c.policy_line AND COALESCE(r.product_type, '') = COALESCE(c.product_type, ''))),
                    'note', r.note)
                  ORDER BY r.occurred_on, r.created_at)
           FROM public.retention_activity_now r
           LEFT JOIN public.retention_point_values v ON v.agency_id = r.agency_id AND v.activity_key = r.activity_key
           WHERE r.agency_id = c.agency_id AND r.status <> 'void'
             AND lower(btrim(COALESCE(r.customer_label, ''))) = c.hh
             AND r.occurred_on BETWEEN COALESCE(sl.submitted_date, c.canceled_on - 365) AND c.canceled_on), '[]'::jsonb)
  FROM c
  LEFT JOIN sale sl ON sl.cid = c.id
  LEFT JOIN claw cw ON cw.cid = c.id
  ORDER BY c.canceled_on DESC, c.created_at DESC;
END $f$;

-- The one list of misses the morning email reads. Which lines run is the recipe's input_config.lines.
--   no_save_before_cancel  a cancelation recorded on the last workday with no Cancelation Saved logged before it
--   claims_no_touch        last week's CPR new claims with fewer Claims Touches logged since (Retention team)
--   sale_no_autopay        a policy sold in the last 30 days with Autopay not ticked (the seller)
--   weekly_reviews         under 5 online reviews this week so far (Retention team)
--   weekly_referrals       under 2 referrals quoted this week so far (Retention team)
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
           public.customer_label(c) || ' ' || COALESCE(c.product_type, c.policy_line) || ' canceled ' || to_char(c.canceled_on, 'Mon FMDD')
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
           public.customer_label(s) || ' ' || COALESCE(sp.product_type, sp.line_of_business) || ' sold ' || to_char(s.submitted_date, 'Mon FMDD')
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
REVOKE ALL ON FUNCTION public.rp_retention_miss_lines(uuid, date) FROM PUBLIC, anon, authenticated;

-- The sender. input_config: lines = which keys run; send_to = 'team' sends each person their own list;
-- anything else sends every person's list to preview_to only. Nobody with nothing missing gets an email.
CREATE OR REPLACE FUNCTION public.send_retention_miss_reminders(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $f$
DECLARE
  cfg jsonb; v_lines text[]; v_team boolean; v_preview text; r RECORD; v_html text; v_to text; v_sent int := 0; v_err jsonb := '[]'::jsonb;
  v_dow int := extract(isodow FROM public.rp_today_central())::int;
BEGIN
  IF v_dow > 5 THEN RETURN jsonb_build_object('skipped', 'weekend'); END IF;
  SELECT input_config INTO cfg FROM public.automation_recipes WHERE id = p_recipe_id;
  cfg := COALESCE(cfg, '{}'::jsonb);
  v_lines := ARRAY(SELECT jsonb_array_elements_text(COALESCE(cfg->'lines', '[]'::jsonb)));
  v_team := COALESCE(cfg->>'send_to', 'preview') = 'team';
  v_preview := NULLIF(btrim(COALESCE(cfg->>'preview_to', '')), '');
  FOR r IN
    SELECT m.team_member_id, m.first_name, m.email, array_agg(m.line_text ORDER BY m.sort_on) AS items
    FROM public.rp_retention_miss_lines(p_agency_id, NULL) m
    WHERE m.line_key = ANY (v_lines)
    GROUP BY m.team_member_id, m.first_name, m.email
  LOOP
    v_to := CASE WHEN v_team THEN r.email ELSE v_preview END;
    CONTINUE WHEN v_to IS NULL;
    v_html := '<p>Good morning ' || r.first_name || ',</p><p>Here''s what''s still open:</p><ul>'
              || (SELECT string_agg('<li>' || replace(replace(i, '&', '&amp;'), '<', '&lt;') || '</li>', '') FROM unnest(r.items) i)
              || '</ul><p>This list stops once each one is done.</p>';
    BEGIN
      PERFORM public.composio_send_email(p_agency_id, v_to,
        CASE WHEN v_team THEN '' ELSE '[Preview for ' || r.first_name || '] ' END
          || 'Open today: ' || cardinality(r.items) || ' thing' || CASE WHEN cardinality(r.items) = 1 THEN '' ELSE 's' END,
        v_html);
      v_sent := v_sent + 1;
    EXCEPTION WHEN OTHERS THEN
      v_err := v_err || jsonb_build_object('team_member_id', r.team_member_id, 'error', SQLERRM);
    END;
  END LOOP;
  RETURN jsonb_build_object('sent', v_sent, 'to_team', v_team, 'errors', v_err);
END $f$;
REVOKE ALL ON FUNCTION public.send_retention_miss_reminders(uuid, uuid) FROM PUBLIC, anon, authenticated;

INSERT INTO public.automation_recipes
  (agency_id, recipe_name, recipe_description, trigger_type, cron_expression, timezone, composio_action, internal_handler, input_config, is_active)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'Retention Morning Reminders',
       'Weekday mornings: one line per miss, only to the person missing it (Peter 2026-10-08). Lines listed in input_config.lines; send_to team or preview.',
       'cron', '50 7 * * 1-5', 'America/Chicago', 'INTERNAL', 'send_retention_miss_reminders',
       '{"lines": ["no_save_before_cancel", "claims_no_touch", "sale_no_autopay", "weekly_reviews", "weekly_referrals"], "send_to": "preview", "preview_to": "paper.newt.management@gmail.com"}'::jsonb,
       false
WHERE NOT EXISTS (SELECT 1 FROM public.automation_recipes WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
                    AND internal_handler = 'send_retention_miss_reminders');

