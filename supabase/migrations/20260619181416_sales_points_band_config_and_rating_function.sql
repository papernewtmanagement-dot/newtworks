-- Bands for Sales Points / TRUE PAY rating (per Peter, 2026-06-19):
--   < 700        Danger
--   700  - 999   Caution
--   1000 - 1499  Good
--   1500 - 1999  Great
--   2000+        Elite
-- Convention: min_threshold inclusive, max_threshold exclusive. NULL = open-ended on that side.

CREATE TABLE IF NOT EXISTS public.sales_points_band_config (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id       uuid NOT NULL,
  rating_name     text NOT NULL,
  min_threshold   numeric,   -- inclusive lower bound; NULL = open-ended down
  max_threshold   numeric,   -- exclusive upper bound; NULL = open-ended up
  display_order   integer NOT NULL,
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (agency_id, rating_name)
);

INSERT INTO public.sales_points_band_config
  (agency_id, rating_name, min_threshold, max_threshold, display_order, notes)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'Danger',  NULL,    700,  1, 'Below $700/week 13-wk rolling avg'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Caution', 700,     1000, 2, '$700 to under $1000'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Good',    1000,    1500, 3, '$1000 to under $1500 — gate for unlimited PTO and 4-day week'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Great',   1500,    2000, 4, '$1500 to under $2000'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Elite',   2000,    NULL, 5, '$2000+')
ON CONFLICT (agency_id, rating_name) DO NOTHING;

-- Pure mapping function: given a $/week value, return the rating name.
-- STABLE (deterministic given input + DB state), no side effects.
CREATE OR REPLACE FUNCTION public.compute_sales_points_rating(
  p_agency_id uuid,
  p_value     numeric
)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT rating_name
  FROM public.sales_points_band_config
  WHERE agency_id = p_agency_id
    AND (min_threshold IS NULL OR p_value >= min_threshold)
    AND (max_threshold IS NULL OR p_value <  max_threshold)
  ORDER BY display_order
  LIMIT 1;
$$;

-- RLS: read-only for any authenticated user in the agency; only owner can write.
ALTER TABLE public.sales_points_band_config ENABLE ROW LEVEL SECURITY;

CREATE POLICY "sales_points_band_read_agency"
ON public.sales_points_band_config
FOR SELECT TO authenticated
USING (
  agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid())
);

CREATE POLICY "sales_points_band_write_owner"
ON public.sales_points_band_config
FOR ALL TO authenticated
USING (
  agency_id IN (
    SELECT u.agency_id FROM public.users u
    WHERE u.auth_user_id = auth.uid() AND u.role = 'owner'
  )
)
WITH CHECK (
  agency_id IN (
    SELECT u.agency_id FROM public.users u
    WHERE u.auth_user_id = auth.uid() AND u.role = 'owner'
  )
);

GRANT EXECUTE ON FUNCTION public.compute_sales_points_rating(uuid, numeric) TO authenticated;
