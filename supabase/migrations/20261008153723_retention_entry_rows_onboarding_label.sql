-- Retention rulings 2026-10-08: History and the customer popup say when a review is onboarding or a touch is over its cap.
CREATE OR REPLACE FUNCTION public.rp_entry_rows(p_agency uuid, p_from date, p_to date, p_include_derived boolean DEFAULT false)
 RETURNS TABLE(kind text, id uuid, occurred_on date, week_end_date date, team_member_id uuid, customer_label text, customer_first_name text, customer_last_initial text, phone_last4 text, summary text, amount numeric, issued_amount numeric, created_at timestamp with time zone, entry_source text, note text, ecrm_url text, meta jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT 'sale'::text, s.id, s.submitted_date, s.week_end_date, s.team_member_id,
         s.customer_label::text, s.customer_first_name::text, s.customer_last_initial::text, s.phone_last4::text,
         (SELECT string_agg(initcap(p.line_of_business) || ' ' || COALESCE(p.product_type,''), ', ' ORDER BY p.line_of_business)
            FROM public.sales_log_products p WHERE p.sales_log_id = s.id)::text,
         s.total_premium,
         (SELECT sum(p.issued_premium) FROM public.sales_log_products p
           WHERE p.sales_log_id = s.id AND p.issued_premium IS NOT NULL),
         s.created_at, COALESCE(s.entry_source,'manual')::text,
         s.note::text, s.ecrm_opportunity_url::text,
         jsonb_build_object('relationship', s.household_status, 'marketing_source', s.marketing_source,
                            'cars', s.vehicle_count, 'on_file_answer', s.on_file_answer)
    FROM public.sales_log s
   WHERE s.agency_id = p_agency AND s.status = 'active'
     AND s.submitted_date >= p_from AND s.submitted_date <= p_to
  UNION ALL
  SELECT 'quote'::text, q.id, q.quote_date, q.week_end_date, q.team_member_id,
         q.customer_label::text, q.customer_first_name::text, q.customer_last_initial::text, q.phone_last4::text,
         (SELECT string_agg(initcap(p.line_of_business) || ' ' || COALESCE(p.product_type,''), ', ' ORDER BY p.line_of_business)
            FROM public.quote_log_products p WHERE p.quote_log_id = q.id)::text,
         NULL::numeric, NULL::numeric, q.created_at, 'manual'::text,
         q.note::text, q.ecrm_opportunity_url::text,
         jsonb_build_object('relationship', q.relationship_type, 'marketing_source', q.marketing_source)
    FROM public.quote_log q
   WHERE q.agency_id = p_agency AND q.status = 'active'
     AND q.quote_date >= p_from AND q.quote_date <= p_to
  UNION ALL
  SELECT 'cancelation'::text, c.id, c.canceled_on, c.week_end_date, c.team_member_id,
         c.customer_label::text, c.customer_first_name::text, c.customer_last_initial::text, c.phone_last4::text,
         (initcap(c.policy_line) || ' ' || COALESCE(c.product_type,'')
          || CASE WHEN c.reinstated_on IS NOT NULL THEN ' · Reinstated ' || to_char(c.reinstated_on, 'FMMM/FMDD') ELSE '' END)::text,
         c.premium, NULL::numeric, c.created_at, 'manual'::text,
         c.note::text, c.ecrm_url::text,
         jsonb_build_object('reason', c.reason, 'replacement', c.is_replacement,
                            'chargeback', c.chargeback_points, 'cars', c.vehicle_count)
    FROM public.cancelation_log c
   WHERE c.agency_id = p_agency AND c.status = 'active'
     AND c.canceled_on >= p_from AND c.canceled_on <= p_to
  UNION ALL
  SELECT 'activity'::text, l.id, l.occurred_on, l.week_end_date, l.team_member_id,
         l.customer_label::text, l.customer_first_name::text, l.customer_last_initial::text, l.phone_last4::text,
         (COALESCE(v.label, l.activity_key)
          -- Peter 2026-10-08: a review within 60 days of the sale is onboarding; a review or
          -- Claims Touch over its cap is logged but not paid.
          || CASE WHEN l.is_onboarding THEN ' (onboarding)' ELSE '' END
          || CASE WHEN l.capped THEN CASE WHEN l.activity_key = 'claims_touch'
                                          THEN ' (not paid: 3 per household in 6 months)'
                                          ELSE ' (not paid: 1 per policy in 5 months)' END ELSE '' END)::text,
         l.points, NULL::numeric, l.created_at, 'manual'::text,
         l.note::text, l.ecrm_url::text,
         jsonb_build_object('activity_key', l.activity_key, 'derived', (l.source <> 'manual'),
                            'line', l.policy_line, 'product', l.product_type, 'premium', l.premium,
                            'save_reason', l.save_reason, 'clears_on', l.credit_available_on,
                            'onboarding', l.is_onboarding, 'capped', l.capped)
    FROM public.retention_activity_now l
    LEFT JOIN public.retention_point_values v
      ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
   WHERE l.agency_id = p_agency AND l.status <> 'void'
     AND (p_include_derived OR l.source = 'manual')
     AND l.occurred_on >= p_from AND l.occurred_on <= p_to
  UNION ALL
  SELECT 'scorecard'::text, f.id, f.scorecard_date, public.rp_week_end(f.scorecard_date), f.team_member_id,
         NULLIF(btrim(COALESCE(f.customer_first_name,'')), '')::text,
         NULLIF(btrim(COALESCE(f.customer_first_name,'')), '')::text,
         NULL::text, f.phone_last4::text,
         ('Conversation score ' || COALESCE(round(f.average_score, 1)::text, '—'))::text,
         f.average_score, NULL::numeric, f.created_at, 'manual'::text,
         f.notes::text, NULL::text,
         jsonb_build_object('average', f.average_score, 'opportunity', f.opportunity_ref)
    FROM public.fit_scorecards f
   WHERE f.agency_id = p_agency
     AND f.scorecard_date >= p_from AND f.scorecard_date <= p_to
  UNION ALL
  SELECT 'appointment'::text, ap.id,
         COALESCE((ap.starts_at AT TIME ZONE 'America/Chicago')::date, ap.set_on),
         ap.week_end_date, ap.team_member_id,
         ap.customer_label::text, ap.customer_first_name::text, ap.customer_last_initial::text, ap.phone_last4::text,
         (CASE WHEN ap.sold_on IS NOT NULL THEN 'Appointment sold'
               WHEN ap.no_show_on IS NOT NULL THEN 'Appointment no show'
               WHEN ap.kept_on IS NOT NULL THEN 'Appointment kept'
               ELSE 'Appointment set' END
          || CASE WHEN ap.line_of_business IS NOT NULL
                  THEN ' · ' || initcap(ap.line_of_business) || ' ' || COALESCE(ap.product_type, '')
                  ELSE '' END)::text,
         NULL::numeric, NULL::numeric, ap.created_at, 'manual'::text,
         ap.note::text, ap.ecrm_url::text,
         jsonb_build_object('set_on', ap.set_on, 'kept_on', ap.kept_on, 'no_show_on', ap.no_show_on,
                            'sold_on', ap.sold_on, 'starts_at', ap.starts_at, 'is_video', ap.is_video)
    FROM public.appointment_log ap
   WHERE ap.agency_id = p_agency AND ap.status = 'active'
     AND COALESCE((ap.starts_at AT TIME ZONE 'America/Chicago')::date, ap.set_on) >= p_from
     AND COALESCE((ap.starts_at AT TIME ZONE 'America/Chicago')::date, ap.set_on) <= p_to;
$function$;

