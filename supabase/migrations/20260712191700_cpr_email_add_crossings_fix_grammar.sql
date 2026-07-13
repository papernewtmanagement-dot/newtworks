-- Adds ⭐ All-Star Crossings + 🔥 Trailblazer Crossings block to weekly CPR digest email.
-- Also fixes prize-draw pluralization ("1 prize draw" vs "2 prize draws").
-- Superseded within same session by 20260712191800 which fixes trailblazer column-name mismatch.
-- Kept for history.

CREATE OR REPLACE FUNCTION public.compose_weekly_cpr_html(p_agency_id uuid, p_week_ending_date date)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_report          public.weekly_cpr_reports;
  v_week_start      date;
  v_start_mon       text;
  v_end_mon         text;
  v_start_day       text;
  v_end_day         text;
  v_subject_range   text;
  v_cpr_url         text;
  v_opener_html     text;
  v_lookahead_html  text;
  v_wtw_html        text := '';
  v_mvp_html        text := '';
  v_mvp_name        text;
  v_mvp_sp          numeric;
  v_mvp_draws       int;
  v_draws_label     text;
  v_crossings_html  text := '';
  v_all_star_rows   text := '';
  v_trailblazer_rows text := '';
  v_payroll_html    text := '';
  v_html            text;
  v_team_quotes     int := 0;
  v_team_sp         numeric := 0;
  v_quote_goal      int := 0;
  v_sp_goal         numeric := 0;
  v_quote_short     int;
  v_sp_short        numeric;
  v_quotes_pass     boolean;
  v_sp_pass         boolean;
BEGIN
  -- (initial version — trailblazer subquery incorrectly referenced value_at_crossing/floor_at_crossing.
  -- fixed in 20260712191800.)
  RAISE EXCEPTION 'This migration was superseded within the same session by 20260712191800.';
END;
$function$;
