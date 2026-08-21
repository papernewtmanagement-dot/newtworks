-- Typical pay ranges by role and licence tier.
--
-- WHY THIS TABLE EXISTS: the careers page reads job_postings (via the
-- careers-site edge function), and job_postings carries salary_min/salary_max
-- per posting. That is what a single advert says, not what the agency
-- actually pays for a seat. This table holds the standing pay the agency
-- works from, so a new posting and a new offer letter both start from the
-- same figures instead of being retyped from memory each time.
--
-- Peter directive 2026-08-20.

CREATE TABLE IF NOT EXISTS public.role_pay_ranges (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id           uuid NOT NULL,
  role_key            text NOT NULL,
  role_label          text NOT NULL,
  tier_key            text NOT NULL,
  tier_label          text NOT NULL,
  pay_type            text NOT NULL CHECK (pay_type = ANY (ARRAY['hourly'::text, 'salary'::text])),
  pay_period          text NOT NULL CHECK (pay_period = ANY (ARRAY['hour'::text, 'year'::text])),
  amount_min          numeric(12,2) NOT NULL,
  amount_max          numeric(12,2) NOT NULL CHECK (amount_max >= amount_min),
  currency            text NOT NULL DEFAULT 'USD',
  requires_license_pc boolean NOT NULL DEFAULT false,
  requires_license_lh boolean NOT NULL DEFAULT false,
  placement_factors   jsonb NOT NULL DEFAULT '[]'::jsonb,
  notes               text,
  sort_order          smallint NOT NULL DEFAULT 0,
  is_active           boolean NOT NULL DEFAULT true,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_role_pay_ranges_role_tier
  ON public.role_pay_ranges (agency_id, role_key, tier_key);

COMMENT ON TABLE public.role_pay_ranges IS
  'Standing pay the agency works from, by role and licence tier. Source for job posting salary bands and for the offer-letter form. Not a payroll table — actual pay per person lives on team.pay_rate.';
COMMENT ON COLUMN public.role_pay_ranges.placement_factors IS
  'Ordered list of what moves a candidate up inside the band. Each entry: {order, factor, preferred}. Empty array for flat tiers.';

ALTER TABLE public.role_pay_ranges ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS role_pay_ranges_auth_read   ON public.role_pay_ranges;
DROP POLICY IF EXISTS role_pay_ranges_auth_insert ON public.role_pay_ranges;
DROP POLICY IF EXISTS role_pay_ranges_auth_update ON public.role_pay_ranges;
DROP POLICY IF EXISTS role_pay_ranges_auth_delete ON public.role_pay_ranges;

CREATE POLICY role_pay_ranges_auth_read ON public.role_pay_ranges
  FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
CREATE POLICY role_pay_ranges_auth_insert ON public.role_pay_ranges
  FOR INSERT TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
CREATE POLICY role_pay_ranges_auth_update ON public.role_pay_ranges
  FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin())
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
CREATE POLICY role_pay_ranges_auth_delete ON public.role_pay_ranges
  FOR DELETE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.role_pay_ranges TO authenticated;

-- Seed
INSERT INTO public.role_pay_ranges
  (agency_id, role_key, role_label, tier_key, tier_label, pay_type, pay_period,
   amount_min, amount_max, requires_license_pc, requires_license_lh,
   placement_factors, notes, sort_order)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365','retention','Retention','unlicensed','No licence yet','hourly','hour',
   16.00, 16.00, false, false, '[]'::jsonb,
   'Starting rate while unlicensed. Moves to the P&C step on licence.', 10),

  ('126794dd-25ff-47d2-a436-724499733365','retention','Retention','pc','Property & Casualty licence','hourly','hour',
   18.00, 18.00, true, false, '[]'::jsonb,
   'Rate once the Property and Casualty licence is held.', 20),

  ('126794dd-25ff-47d2-a436-724499733365','retention','Retention','pc_lh','Property & Casualty plus Life & Health','hourly','hour',
   20.00, 20.00, true, true, '[]'::jsonb,
   'Top retention step. Requires both the Property and Casualty licence and the Life and Health licence.', 30),

  ('126794dd-25ff-47d2-a436-724499733365','sales','Sales','base','Base salary','salary','year',
   30000.00, 40000.00, false, false,
   '[{"order":1,"factor":"Sales experience","preferred":false},
     {"order":2,"factor":"Needs-based sales experience","preferred":true},
     {"order":3,"factor":"Needs-based selling in insurance or financial services","preferred":true},
     {"order":4,"factor":"Needs-based selling inside State Farm","preferred":true}]'::jsonb,
   'Base only. Where someone lands in the band depends on how far they go down the four factors, in order. Commission is separate and is not included in this range.', 40),

  ('126794dd-25ff-47d2-a436-724499733365','life_specialist','Life Specialist','base','Base salary','salary','year',
   40000.00, 50000.00, true, true,
   '[{"order":1,"factor":"Year one base","preferred":false},
     {"order":2,"factor":"Year two base — requires year one production targets met","preferred":false},
     {"order":3,"factor":"Year three onward base — requires year two production targets met","preferred":false}]'::jsonb,
   'Stepped base from the locked Life Specialist comp plan: 40,000 in year one, 45,000 in year two, 50,000 from year three, each step gated on the prior year hitting its production targets. The step gates go in the offer letter in writing. Commission and bonuses are separate.', 50)
ON CONFLICT (agency_id, role_key, tier_key) DO NOTHING;