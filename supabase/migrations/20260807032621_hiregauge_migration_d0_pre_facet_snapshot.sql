CREATE TABLE IF NOT EXISTS hiregauge_role_fit_pre_facet_snapshot (
  agency_id uuid,
  candidate_id uuid,
  role_category text,
  fit_score numeric,
  is_best_fit boolean,
  model_tag text DEFAULT 'competency_v4_pre_facet',
  captured_at timestamptz DEFAULT now(),
  UNIQUE(agency_id, candidate_id, role_category)
);

INSERT INTO hiregauge_role_fit_pre_facet_snapshot (agency_id, candidate_id, role_category, fit_score, is_best_fit)
SELECT
  hc.agency_id,
  hc.id,
  r.role_category,
  (CASE r.role_category
    WHEN 'sales_outbound'       THEN b.sales_outbound_fit_score
    WHEN 'sales_inbound'        THEN b.sales_inbound_fit_score
    WHEN 'sales_in_book'        THEN b.sales_in_book_fit_score
    WHEN 'retention_reception'  THEN b.retention_reception_fit_score
    WHEN 'retention_escalation' THEN b.retention_escalation_fit_score
    WHEN 'retention_support'    THEN b.retention_support_fit_score
    WHEN 'aspirant'             THEN b.aspirant_fit_score
  END)::numeric,
  (r.role_category = b.best_role)
FROM public.hiring_candidates hc
CROSS JOIN (VALUES
  ('sales_outbound'),('sales_inbound'),('sales_in_book'),
  ('retention_reception'),('retention_escalation'),('retention_support'),
  ('aspirant')
) AS r(role_category)
CROSS JOIN LATERAL public.assessment_best_fit_role(hc.id) b
WHERE hc.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND hc.achievement_striving IS NOT NULL
  AND hc.id <> '97a56442-0be5-41f4-a2ba-c4b2f01f079a'
ON CONFLICT (agency_id, candidate_id, role_category) DO NOTHING;
