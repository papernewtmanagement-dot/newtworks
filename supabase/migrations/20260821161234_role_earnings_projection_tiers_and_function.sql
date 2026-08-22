-- Earnings projection by role, performer tier, and year of employment.
-- Feeds the Growth > Earning Potential sub-tab.
--
-- DESIGN NOTES (read before editing):
--
-- 1. TIER MULTIPLIERS are fitted to a Paretian (power-law) performance
--    distribution, not a normal one. Basis: O'Boyle & Aguinis (2012),
--    "The Best and the Rest: Revisiting the Norm of Normality of Individual
--    Job Performance," Personnel Psychology 65(1):79-119 (198 samples,
--    N=633,263). Individual output in sales roles is right-skewed; evenly
--    spaced tiers would understate the tail badly.
--    Shape parameter alpha = 3.0. Multiplier at percentile p, anchored so
--    that the midpoint of the bottom 75% equals 1.00:
--        m(p) = ((1 - 0.375) / (1 - p)) ^ (1/3)
--    Peter's four buckets and their midpoints:
--        Rock          bottom 75%   p=0.375  -> 1.00
--        Rock n' Roll  next 19%     p=0.845  -> 1.61
--        Rockstar      next 5%      p=0.965  -> 2.64
--        Rock Legend   top 1%       p=0.995  -> 5.09
--    Two independent calibration checks, both clean:
--      (a) John and Tommy run ~156 sales points/wk against a 100/wk target
--          = 1.56x, landing on Rock n' Roll.
--      (b) The locked Life Specialist plan puts steady state at ~$97.5K Life
--          premium and top quartile at ~$152.5K = 1.56x, same band.
--
-- 2. BASE PAY comes from role_pay_ranges (the published bands). The
--    progression WITHIN those bands is a promotion ladder keyed to tier:
--    faster tiers reach the next step sooner. Retention steps are licence-
--    gated ($16 unlicensed / $18 P&C / $20 P&C+L&H). Life Specialist steps
--    are production-gated per the locked plan ($40K/$45K/$50K). Sales hires
--    into the $30-40K band then promotes to Account Manager and Unit Manager
--    at rates observed on the live roster.
--
-- 3. BONUS POOL SHARE rates are computed LIVE from the residual pool, never
--    stored, per core_principles compensation_data_freshness (650).
--    Simplifying assumption, stated plainly on the page: the pool is modelled
--    as growing with production at today's dollars-per-sales-point rate. In
--    reality the pool is a fixed envelope that a high producer takes a larger
--    slice of, while also enlarging the envelope by driving agency revenue.
--    Those two effects run opposite and roughly cancel.

CREATE TABLE IF NOT EXISTS public.earnings_projection_tiers (
  agency_id        uuid NOT NULL,
  tier_key         text NOT NULL,
  tier_label       text NOT NULL,
  applicant_pct    numeric(5,2) NOT NULL,
  multiplier       numeric(6,3) NOT NULL,
  descriptor       text NOT NULL,
  sort_order       int  NOT NULL,
  is_active        boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agency_id, tier_key)
);

ALTER TABLE public.earnings_projection_tiers ENABLE ROW LEVEL SECURITY;

DO $rls$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE schemaname='public' AND tablename='earnings_projection_tiers'
                   AND policyname='authed_read_earnings_projection_tiers') THEN
    CREATE POLICY authed_read_earnings_projection_tiers
      ON public.earnings_projection_tiers FOR SELECT TO authenticated USING (true);
  END IF;
END
$rls$;

INSERT INTO public.earnings_projection_tiers
  (agency_id, tier_key, tier_label, applicant_pct, multiplier, descriptor, sort_order)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365','rock','Rock',75.00,1.000,
   'Consistent. Shows up, does the work, sells at an average clip.',10),
  ('126794dd-25ff-47d2-a436-724499733365','rock_n_roll','Rock nّ Roll',19.00,1.610,
   'Consistent and having fun. Good at selling, and it shows.',20),
  ('126794dd-25ff-47d2-a436-724499733365','rockstar','Rockstar',5.00,2.640,
   'Consistent, having fun, and obsessed. Great at selling.',30),
  ('126794dd-25ff-47d2-a436-724499733365','rock_legend','Rock Legend',1.00,5.090,
   'Consistent, having fun, obsessed, and multiplying. Incredible at selling, and everyone around them gets better because they are here.',40)
ON CONFLICT (agency_id, tier_key) DO UPDATE
  SET tier_label = EXCLUDED.tier_label,
      applicant_pct = EXCLUDED.applicant_pct,
      multiplier = EXCLUDED.multiplier,
      descriptor = EXCLUDED.descriptor,
      sort_order = EXCLUDED.sort_order,
      updated_at = now();

UPDATE public.earnings_projection_tiers
   SET tier_label = 'Rock n'' Roll'
 WHERE tier_key = 'rock_n_roll';