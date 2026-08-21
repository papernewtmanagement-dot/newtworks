CREATE TABLE IF NOT EXISTS public.cpr_campaigns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  campaign_type text NOT NULL CHECK (campaign_type IN ('defectors','single_line_at_risk','auto_fire_renewals','missing_onboarding_cases')),
  created_on date NOT NULL,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cpr_campaigns_agency_type_date
  ON public.cpr_campaigns (agency_id, campaign_type, created_on DESC);

ALTER TABLE public.cpr_campaigns ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "cpr_campaigns_anon_select" ON public.cpr_campaigns;
CREATE POLICY "cpr_campaigns_anon_select" ON public.cpr_campaigns FOR SELECT TO anon USING (true);

DROP POLICY IF EXISTS "cpr_campaigns_authenticated_all" ON public.cpr_campaigns;
CREATE POLICY "cpr_campaigns_authenticated_all" ON public.cpr_campaigns FOR ALL TO authenticated USING (true) WITH CHECK (true);

GRANT SELECT ON public.cpr_campaigns TO anon;
GRANT ALL ON public.cpr_campaigns TO authenticated;
