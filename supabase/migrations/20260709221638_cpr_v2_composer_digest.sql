-- CPR v2 email: lightweight digest (opener + link + looking-ahead + signoff).
-- Replaces the ~34KB full-render composer. All the detail lives on the CPR page.
--
-- Design principle: one source of truth (the CPR page). Email is a nudge with the
-- Saturday drafted-narrative (opener + looking-ahead) and a tap-through link.
-- No tables, no per-person breakdowns, no metrics — those all drift when they
-- duplicate the page.
--
-- Prior helper functions (render_cpr_team_checklist_grid_html, render_cpr_personal_checklist_html,
-- render_cpr_section_11_html, render_cpr_eur_html, render_cpr_campaigns_html, render_cpr_prize_cart_html,
-- render_cpr_marketing_bonus_html) are left in place — no longer called by the composer but retained
-- for reference and reversibility.
--
-- Applied via Supabase MCP 2026-07-09; mirrored here for grep-ability + diff visibility.

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
  v_html            text;
BEGIN
  SELECT * INTO v_report
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_ending_date;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No weekly_cpr_reports row for agency=% week=%', p_agency_id, p_week_ending_date;
  END IF;

  v_week_start := p_week_ending_date - 6;
  v_cpr_url := 'https://newtworks.vercel.app/cpr/' || to_char(p_week_ending_date, 'YYYY-MM-DD');

  -- Match sender's subject-line date format (cross-month-safe)
  v_start_mon := upper(to_char(v_week_start,       'Mon'));
  v_end_mon   := upper(to_char(p_week_ending_date, 'Mon'));
  v_start_day := to_char(v_week_start,       'FMDD');
  v_end_day   := to_char(p_week_ending_date, 'FMDD');
  IF v_start_mon = v_end_mon THEN
    v_subject_range := v_start_mon || ' ' || v_start_day || '-' || v_end_day;
  ELSE
    v_subject_range := v_start_mon || ' ' || v_start_day || ' - ' || v_end_mon || ' ' || v_end_day;
  END IF;

  -- Escape opener + looking-ahead text, convert \n to <br>
  v_opener_html := COALESCE(
    NULLIF(replace(replace(replace(v_report.opener_text, '<', '&lt;'), '>', '&gt;'), E'\n', '<br>'), ''),
    '<em style="color:#94a3b8">Opener not yet drafted.</em>'
  );
  v_lookahead_html := COALESCE(
    NULLIF(replace(replace(replace(v_report.looking_next_week_text, '<', '&lt;'), '>', '&gt;'), E'\n', '<br>'), ''),
    '<em style="color:#94a3b8">Looking ahead not yet drafted.</em>'
  );

  v_html :=
    '<div style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Oxygen,Ubuntu,sans-serif;max-width:600px;margin:0 auto;padding:20px;color:#1e293b">' ||
      '<h2 style="margin:0 0 20px;font-size:20px;color:#1e293b">📊 CPR RECAP — WEEK OF ' || v_subject_range || '</h2>' ||
      '<div style="color:#b91c1c;font-size:15px;line-height:1.6;margin-bottom:18px">' || v_opener_html || '</div>' ||
      '<div style="margin:20px 0">' ||
        '<a href="' || v_cpr_url || '" style="display:inline-block;padding:10px 18px;background:#1e40af;color:#ffffff;text-decoration:none;border-radius:6px;font-weight:600">📋 View full CPR report →</a>' ||
      '</div>' ||
      '<h3 style="margin:24px 0 8px;font-size:16px;color:#1e293b">🎯 LOOKING AT NEXT WEEK</h3>' ||
      '<div style="color:#1e40af;font-size:15px;line-height:1.6;margin-bottom:24px">' || v_lookahead_html || '</div>' ||
      '<p style="color:#64748b;font-size:14px;margin:24px 0 0">— Peter</p>' ||
    '</div>';

  RETURN v_html;
END;
$function$;
