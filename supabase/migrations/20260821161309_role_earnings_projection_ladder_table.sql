-- Base pay ladder: annual base by role, tier and year of employment.
-- Editable by Peter without a code change. Sourced from role_pay_ranges bands
-- plus rates observed on the live roster for the promotion steps above the
-- Sales hire band (Account Manager 41,600; Unit Manager 52,000-54,080).
CREATE TABLE IF NOT EXISTS public.earnings_projection_base_ladder (
  agency_id    uuid NOT NULL,
  role_key     text NOT NULL,
  tier_key     text NOT NULL,
  year_num     int  NOT NULL CHECK (year_num BETWEEN 1 AND 5),
  annual_base  numeric(12,2) NOT NULL,
  step_label   text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agency_id, role_key, tier_key, year_num)
);

ALTER TABLE public.earnings_projection_base_ladder ENABLE ROW LEVEL SECURITY;

DO $rls$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE schemaname='public' AND tablename='earnings_projection_base_ladder'
                   AND policyname='authed_read_earnings_projection_base_ladder') THEN
    CREATE POLICY authed_read_earnings_projection_base_ladder
      ON public.earnings_projection_base_ladder FOR SELECT TO authenticated USING (true);
  END IF;
END
$rls$;

WITH src(role_key, tier_key, bases, labels) AS (
  VALUES
    -- RETENTION: hourly steps x 2080. Licence-gated per role_pay_ranges.
    ('retention','rock',        ARRAY[16,18,18,18,18]::numeric[],
      ARRAY['No licence yet','P&C licence','P&C licence','P&C licence','P&C licence']),
    ('retention','rock_n_roll', ARRAY[16,18,20,20,20]::numeric[],
      ARRAY['No licence yet','P&C licence','P&C + L&H','P&C + L&H','P&C + L&H']),
    ('retention','rockstar',    ARRAY[18,20,20,20,20]::numeric[],
      ARRAY['P&C licence','P&C + L&H','P&C + L&H','P&C + L&H','P&C + L&H']),
    ('retention','rock_legend', ARRAY[18,20,20,20,20]::numeric[],
      ARRAY['P&C licence','P&C + L&H','P&C + L&H','P&C + L&H','P&C + L&H']),
    -- SALES: hires into the 30-40K band, then promotes.
    ('sales','rock',        ARRAY[35000,36400,37800,39200,40000]::numeric[],
      ARRAY['Hire band','Hire band','Hire band','Hire band','Top of hire band']),
    ('sales','rock_n_roll', ARRAY[35000,40000,41600,41600,52000]::numeric[],
      ARRAY['Hire band','Top of hire band','Account Manager','Account Manager','Unit Manager']),
    ('sales','rockstar',    ARRAY[35000,41600,52000,52000,54080]::numeric[],
      ARRAY['Hire band','Account Manager','Unit Manager','Unit Manager','Senior Unit Manager']),
    ('sales','rock_legend', ARRAY[40000,52000,54080,54080,54080]::numeric[],
      ARRAY['Top of hire band','Unit Manager','Senior Unit Manager','Senior Unit Manager','Senior Unit Manager']),
    -- LIFE SPECIALIST: stepped and production-gated per the locked plan.
    ('life_specialist','rock',        ARRAY[40000,45000,45000,45000,45000]::numeric[],
      ARRAY['Year one','Year two step','Year three gate missed','Year three gate missed','Year three gate missed']),
    ('life_specialist','rock_n_roll', ARRAY[40000,45000,50000,50000,50000]::numeric[],
      ARRAY['Year one','Year two step','Year three step','Top of band','Top of band']),
    ('life_specialist','rockstar',    ARRAY[40000,45000,50000,50000,50000]::numeric[],
      ARRAY['Year one','Year two step','Year three step','Top of band','Top of band']),
    ('life_specialist','rock_legend', ARRAY[40000,45000,50000,50000,50000]::numeric[],
      ARRAY['Year one','Year two step','Year three step','Top of band','Top of band'])
)
INSERT INTO public.earnings_projection_base_ladder
  (agency_id, role_key, tier_key, year_num, annual_base, step_label)
SELECT '126794dd-25ff-47d2-a436-724499733365'::uuid,
       s.role_key, s.tier_key, y.n,
       CASE WHEN s.role_key = 'retention' THEN s.bases[y.n] * 2080 ELSE s.bases[y.n] END,
       s.labels[y.n]
FROM src s CROSS JOIN generate_series(1,5) AS y(n)
ON CONFLICT (agency_id, role_key, tier_key, year_num) DO UPDATE
  SET annual_base = EXCLUDED.annual_base,
      step_label  = EXCLUDED.step_label,
      updated_at  = now();