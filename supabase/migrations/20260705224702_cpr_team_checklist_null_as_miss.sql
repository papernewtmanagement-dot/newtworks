-- Fix: render_cpr_team_checklist_grid_html treated NULL as ✓ via COALESCE(x, true).
-- Now matches page + personal-checklist convention: true → ✓ green, false → ✕ red, NULL → — grey.
CREATE OR REPLACE FUNCTION public.render_cpr_team_checklist_grid_html(p_report weekly_cpr_reports)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  WITH cell(k, label) AS (
    VALUES
      ('shareds_done',       'Shared Outlook folders'),
      ('texts_done',         'Texts recorded'),
      ('deposits_done',      'Deposits finalized'),
      ('appts_done',         'Appointments formatted'),
      ('tasks_done',         'Tasks cleared'),
      ('cases_done',         'Onboarding cases created'),
      ('no_onboarding_done', 'Non-onboarding cases closed'),
      ('no_fu_task_done',    'Missing follow-up'),
      ('new_opps_done',      'New leads'),
      ('no_phone_done',      'No phone'),
      ('bad_data_done',      'Quotes w/ missing data')
  ),
  render(k, label, glyph) AS (
    SELECT
      k, label,
      CASE
        WHEN (row_to_json(p_report)::jsonb ->> k)::boolean IS TRUE
          THEN '<span style="color:#16a34a;font-weight:700">✓</span>'
        WHEN (row_to_json(p_report)::jsonb ->> k)::boolean IS FALSE
          THEN '<span style="color:#dc2626;font-weight:700">✕</span>'
        ELSE '<span style="color:#cbd5e1;font-weight:700">—</span>'
      END
    FROM cell
  )
  SELECT
       '<table style="width:100%;border-collapse:collapse;font-size:12px;color:#334155"><tbody>'
    || '<tr><td style="padding:4px 8px;width:50%">' || (SELECT glyph FROM render WHERE k='shareds_done')       || ' Shared Outlook folders</td>'
    || '<td style="padding:4px 8px;width:50%">'    || (SELECT glyph FROM render WHERE k='texts_done')         || ' Texts recorded</td></tr>'
    || '<tr><td style="padding:4px 8px">'          || (SELECT glyph FROM render WHERE k='deposits_done')      || ' Deposits finalized</td>'
    || '<td style="padding:4px 8px">'              || (SELECT glyph FROM render WHERE k='appts_done')         || ' Appointments formatted</td></tr>'
    || '<tr><td style="padding:4px 8px">'          || (SELECT glyph FROM render WHERE k='tasks_done')         || ' Tasks cleared</td>'
    || '<td style="padding:4px 8px">'              || (SELECT glyph FROM render WHERE k='cases_done')         || ' Onboarding cases created</td></tr>'
    || '<tr><td style="padding:4px 8px" colspan="2">' || (SELECT glyph FROM render WHERE k='no_onboarding_done') || ' Non-onboarding cases closed</td></tr>'
    || '</tbody></table>'
    || '<div style="height:10px"></div>'
    || '<div style="font-size:10px;font-weight:800;color:#64748b;letter-spacing:0.6px;text-transform:uppercase;margin:0 0 6px 4px">Opp Lists Cleared</div>'
    || '<table style="width:100%;border-collapse:collapse;font-size:12px;color:#334155"><tbody>'
    || '<tr><td style="padding:4px 8px;width:50%">' || (SELECT glyph FROM render WHERE k='no_fu_task_done')    || ' Missing follow-up</td>'
    || '<td style="padding:4px 8px;width:50%">'    || (SELECT glyph FROM render WHERE k='new_opps_done')     || ' New leads</td></tr>'
    || '<tr><td style="padding:4px 8px">'          || (SELECT glyph FROM render WHERE k='no_phone_done')     || ' No phone</td>'
    || '<td style="padding:4px 8px">'              || (SELECT glyph FROM render WHERE k='bad_data_done')     || ' Quotes w/ missing data</td></tr>'
    || '</tbody></table>';
$function$;
