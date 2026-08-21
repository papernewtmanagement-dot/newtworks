-- Compute lapse rate at runtime from agency_snapshot YTD rows.
-- Returns 4 rows per agency: auto, fire, life, blended.
-- Blended is dollar-weighted by trailing-12-month renewal commission from comp_recap.

CREATE OR REPLACE FUNCTION public.compute_lapse_rate(
  p_agency_id uuid,
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS TABLE (
  line text,
  starting_pif int,
  lost_ytd int,
  days_elapsed int,
  ytd_rate numeric,
  annualized_rate numeric,
  source_snapshot_date date
)
LANGUAGE sql STABLE
AS $fn$
  WITH latest_ytd AS (
    SELECT s.*
    FROM public.agency_snapshot s
    WHERE s.agency_id = p_agency_id
      AND s.snapshot_date <= p_as_of
      AND s.auto_lost_ytd IS NOT NULL
    ORDER BY s.snapshot_date DESC
    LIMIT 1
  ),
  anchor AS (
    SELECT a2.*
    FROM latest_ytd l
    JOIN LATERAL (
      SELECT s2.*
      FROM public.agency_snapshot s2
      WHERE s2.agency_id = l.agency_id
        AND s2.snapshot_date <= make_date(EXTRACT(YEAR FROM l.snapshot_date)::int, 1, 1)
        AND s2.auto_pif IS NOT NULL
      ORDER BY s2.snapshot_date DESC
      LIMIT 1
    ) a2 ON true
  ),
  base AS (
    SELECT
      l.snapshot_date AS as_of,
      a.auto_pif AS start_auto, l.auto_lost_ytd AS lost_auto,
      a.fire_pif AS start_fire, l.fire_lost_ytd AS lost_fire,
      a.life_pif AS start_life, l.life_lost_ytd AS lost_life,
      GREATEST((l.snapshot_date - make_date(EXTRACT(YEAR FROM l.snapshot_date)::int, 1, 1))::int, 1) AS days
    FROM latest_ytd l, anchor a
  ),
  per_line AS (
    SELECT 'auto'::text AS line, b.start_auto AS pif, b.lost_auto AS lost, b.days, b.as_of FROM base b
    UNION ALL SELECT 'fire', b.start_fire, b.lost_fire, b.days, b.as_of FROM base b
    UNION ALL SELECT 'life', b.start_life, b.lost_life, b.days, b.as_of FROM base b
  ),
  rates AS (
    SELECT
      p.line, p.pif, p.lost, p.days, p.as_of,
      (p.lost::numeric / NULLIF(p.pif, 0)) AS ytd_rate,
      ((p.lost::numeric / NULLIF(p.pif, 0)) * (365.0 / p.days)) AS annualized_rate
    FROM per_line p
  ),
  weights AS (
    SELECT
      SUM(CASE WHEN comp_category = 'auto_renewal' THEN amount ELSE 0 END) AS w_auto,
      SUM(CASE WHEN comp_category = 'fire_renewal' THEN amount ELSE 0 END) AS w_fire,
      SUM(CASE WHEN comp_category = 'life_renewal' THEN amount ELSE 0 END) AS w_life
    FROM public.comp_recap
    WHERE agency_id = p_agency_id
      AND make_date(period_year, period_month, 1) > (p_as_of - INTERVAL '12 months')::date
      AND make_date(period_year, period_month, 1) <= p_as_of
      AND comp_category IN ('auto_renewal','fire_renewal','life_renewal')
  ),
  blended AS (
    SELECT
      'blended'::text AS line,
      NULL::int AS pif,
      NULL::int AS lost,
      (SELECT b.days FROM base b) AS days,
      (SELECT b.as_of FROM base b) AS as_of,
      NULL::numeric AS ytd_rate,
      (
        COALESCE((SELECT annualized_rate FROM rates WHERE line='auto'), 0) * COALESCE(w.w_auto, 0) +
        COALESCE((SELECT annualized_rate FROM rates WHERE line='fire'), 0) * COALESCE(w.w_fire, 0) +
        COALESCE((SELECT annualized_rate FROM rates WHERE line='life'), 0) * COALESCE(w.w_life, 0)
      ) / NULLIF(COALESCE(w.w_auto,0) + COALESCE(w.w_fire,0) + COALESCE(w.w_life,0), 0) AS annualized_rate
    FROM weights w
  )
  SELECT r.line, r.pif::int, r.lost::int, r.days::int, r.ytd_rate, r.annualized_rate, r.as_of
  FROM rates r
  UNION ALL
  SELECT b.line, b.pif, b.lost, b.days::int, b.ytd_rate, b.annualized_rate, b.as_of
  FROM blended b;
$fn$;

COMMENT ON FUNCTION public.compute_lapse_rate IS
  'Annual lapse rate computed live from agency_snapshot YTD rows. Per-line + dollar-weighted blended. Never store the result; always call live. See operational_rule "Lapse rate — never store, compute at runtime".';

-- Convenience view for the current agency-as-of-today
CREATE OR REPLACE VIEW public.v_lapse_rate_current AS
SELECT a.id AS agency_id, c.line, c.starting_pif, c.lost_ytd, c.days_elapsed,
       c.ytd_rate, c.annualized_rate, c.source_snapshot_date
FROM public.agency a
CROSS JOIN LATERAL public.compute_lapse_rate(a.id) c;
