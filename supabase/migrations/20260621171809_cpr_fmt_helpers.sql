-- CPR email/page formatter helpers. Zero → "—", null → "—".
-- Used by compose_weekly_cpr_html and any render_cpr_section_*_html helpers.

CREATE OR REPLACE FUNCTION public.cpr_fmt_money(p_val numeric, p_decimals int DEFAULT 2)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_val IS NULL OR ROUND(p_val, p_decimals) = 0 THEN '—'
    ELSE '$' || to_char(
      ROUND(p_val, p_decimals),
      CASE WHEN p_decimals = 0 THEN 'FM999,999,999' ELSE 'FM999,999,999.00' END
    )
  END;
$$;

CREATE OR REPLACE FUNCTION public.cpr_fmt_int(p_val numeric)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_val IS NULL OR ROUND(p_val) = 0 THEN '—'
    ELSE to_char(ROUND(p_val), 'FM999,999,999')
  END;
$$;

CREATE OR REPLACE FUNCTION public.cpr_fmt_hours(p_val numeric)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_val IS NULL OR ROUND(p_val, 2) = 0 THEN '—'
    ELSE to_char(ROUND(p_val, 2), 'FM999990.00')
  END;
$$;

CREATE OR REPLACE FUNCTION public.cpr_fmt_signed_money(p_val numeric, p_decimals int DEFAULT 0)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_val IS NULL OR ROUND(p_val, p_decimals) = 0 THEN '—'
    WHEN p_val > 0 THEN '+$' || to_char(
      ROUND(p_val, p_decimals),
      CASE WHEN p_decimals = 0 THEN 'FM999,999,999' ELSE 'FM999,999,999.00' END
    )
    ELSE '-$' || to_char(
      ROUND(ABS(p_val), p_decimals),
      CASE WHEN p_decimals = 0 THEN 'FM999,999,999' ELSE 'FM999,999,999.00' END
    )
  END;
$$;

CREATE OR REPLACE FUNCTION public.cpr_fmt_signed_int(p_val numeric)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_val IS NULL OR ROUND(p_val) = 0 THEN '—'
    WHEN p_val > 0 THEN '+' || to_char(ROUND(p_val), 'FM999,999,999')
    ELSE to_char(ROUND(p_val), 'FM999,999,999')
  END;
$$;

COMMENT ON FUNCTION public.cpr_fmt_money(numeric, int) IS 'CPR formatter: $X,XXX.XX; zero or null → "—"';
COMMENT ON FUNCTION public.cpr_fmt_int(numeric) IS 'CPR formatter: integer; zero or null → "—"';
COMMENT ON FUNCTION public.cpr_fmt_hours(numeric) IS 'CPR formatter: X.XX hours; zero or null → "—"';
COMMENT ON FUNCTION public.cpr_fmt_signed_money(numeric, int) IS 'CPR formatter: +/-$X with sign prefix; zero or null → "—"';
COMMENT ON FUNCTION public.cpr_fmt_signed_int(numeric) IS 'CPR formatter: +/-X integer with sign prefix; zero or null → "—"';
