-- Step 1 of Newtworks competency layer rebuild (confirmed 2026-08-02)
-- Adds role_category to the legacy floors table and creates the new
-- hiregauge_competency_weights table, seeded with 84 rows (12 competencies x 7 roles)
-- per the role matrix locked by Peter 2026-08-02.

ALTER TABLE public.hiregauge_competency_floors
  ADD COLUMN IF NOT EXISTS role_category text;

CREATE TABLE IF NOT EXISTS public.hiregauge_competency_weights (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  role_category text NOT NULL,
  competency_name text NOT NULL,
  tier text NOT NULL CHECK (tier IN ('critical','important','supporting')),
  weight numeric NOT NULL CHECK (weight IN (1,2,3)),
  notes text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by text,
  UNIQUE (agency_id, role_category, competency_name)
);

ALTER TABLE public.hiregauge_competency_weights ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_all_hiregauge_competency_weights" ON public.hiregauge_competency_weights;
CREATE POLICY "anon_all_hiregauge_competency_weights"
  ON public.hiregauge_competency_weights FOR ALL TO anon USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "authenticated_all_hiregauge_competency_weights" ON public.hiregauge_competency_weights;
CREATE POLICY "authenticated_all_hiregauge_competency_weights"
  ON public.hiregauge_competency_weights FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Role order: sales_outbound, sales_inbound, sales_in_book, retention_escalation,
--             retention_reception, retention_support, aspirant
-- C=critical/weight3(hard floor)  I=important/weight2  S=supporting/weight1

INSERT INTO public.hiregauge_competency_weights
  (agency_id, role_category, competency_name, tier, weight, updated_by)
VALUES
('126794dd-25ff-47d2-a436-724499733365','sales_outbound','drive_work_intensity','critical',3,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_inbound','drive_work_intensity','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_in_book','drive_work_intensity','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_escalation','drive_work_intensity','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_reception','drive_work_intensity','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_support','drive_work_intensity','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','aspirant','drive_work_intensity','critical',3,'claude_build_2026-08-03'),

('126794dd-25ff-47d2-a436-724499733365','sales_outbound','persuasive_influence','critical',3,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_inbound','persuasive_influence','critical',3,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_in_book','persuasive_influence','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_escalation','persuasive_influence','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_reception','persuasive_influence','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_support','persuasive_influence','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','aspirant','persuasive_influence','important',2,'claude_build_2026-08-03'),

('126794dd-25ff-47d2-a436-724499733365','sales_outbound','rapport_building','critical',3,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_inbound','rapport_building','critical',3,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_in_book','rapport_building','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_escalation','rapport_building','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_reception','rapport_building','critical',3,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_support','rapport_building','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','aspirant','rapport_building','important',2,'claude_build_2026-08-03'),

('126794dd-25ff-47d2-a436-724499733365','sales_outbound','needs_discovery','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_inbound','needs_discovery','critical',3,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_in_book','needs_discovery','critical',3,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_escalation','needs_discovery','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_reception','needs_discovery','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_support','needs_discovery','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','aspirant','needs_discovery','important',2,'claude_build_2026-08-03'),

('126794dd-25ff-47d2-a436-724499733365','sales_outbound','resilience_under_rejection','critical',3,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_inbound','resilience_under_rejection','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_in_book','resilience_under_rejection','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_escalation','resilience_under_rejection','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_reception','resilience_under_rejection','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_support','resilience_under_rejection','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','aspirant','resilience_under_rejection','important',2,'claude_build_2026-08-03'),

('126794dd-25ff-47d2-a436-724499733365','sales_outbound','composure_under_pressure','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_inbound','composure_under_pressure','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_in_book','composure_under_pressure','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_escalation','composure_under_pressure','critical',3,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_reception','composure_under_pressure','critical',3,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_support','composure_under_pressure','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','aspirant','composure_under_pressure','important',2,'claude_build_2026-08-03'),

('126794dd-25ff-47d2-a436-724499733365','sales_outbound','accuracy_procedural_discipline','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_inbound','accuracy_procedural_discipline','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_in_book','accuracy_procedural_discipline','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_escalation','accuracy_procedural_discipline','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_reception','accuracy_procedural_discipline','critical',3,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_support','accuracy_procedural_discipline','critical',3,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','aspirant','accuracy_procedural_discipline','important',2,'claude_build_2026-08-03'),

('126794dd-25ff-47d2-a436-724499733365','sales_outbound','rule_compliance_adherence','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_inbound','rule_compliance_adherence','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_in_book','rule_compliance_adherence','critical',3,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_escalation','rule_compliance_adherence','critical',3,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_reception','rule_compliance_adherence','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_support','rule_compliance_adherence','critical',3,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','aspirant','rule_compliance_adherence','important',2,'claude_build_2026-08-03'),

('126794dd-25ff-47d2-a436-724499733365','sales_outbound','integrity','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_inbound','integrity','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_in_book','integrity','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_escalation','integrity','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_reception','integrity','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_support','integrity','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','aspirant','integrity','critical',3,'claude_build_2026-08-03'),

('126794dd-25ff-47d2-a436-724499733365','sales_outbound','judgment_escalation','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_inbound','judgment_escalation','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_in_book','judgment_escalation','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_escalation','judgment_escalation','critical',3,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_reception','judgment_escalation','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_support','judgment_escalation','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','aspirant','judgment_escalation','critical',3,'claude_build_2026-08-03'),

('126794dd-25ff-47d2-a436-724499733365','sales_outbound','coachability_team_contribution','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_inbound','coachability_team_contribution','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_in_book','coachability_team_contribution','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_escalation','coachability_team_contribution','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_reception','coachability_team_contribution','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_support','coachability_team_contribution','important',2,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','aspirant','coachability_team_contribution','important',2,'claude_build_2026-08-03'),

('126794dd-25ff-47d2-a436-724499733365','sales_outbound','autonomy_ownership','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_inbound','autonomy_ownership','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','sales_in_book','autonomy_ownership','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_escalation','autonomy_ownership','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_reception','autonomy_ownership','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','retention_support','autonomy_ownership','supporting',1,'claude_build_2026-08-03'),
('126794dd-25ff-47d2-a436-724499733365','aspirant','autonomy_ownership','critical',3,'claude_build_2026-08-03')
ON CONFLICT (agency_id, role_category, competency_name) DO NOTHING;
