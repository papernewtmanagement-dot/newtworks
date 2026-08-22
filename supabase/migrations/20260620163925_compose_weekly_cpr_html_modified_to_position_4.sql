-- Realign email Requirements column order to match webpage CPRDetail.jsx + canon dc5e694a.
-- Move Modified column from position 7 (between Paid and Next Wk) to position 4 (right after This Wk).
-- Two surgical reorders inside compose_weekly_cpr_html:
--   1. Header <th> sequence
--   2. v_requirements_rows body <td> sequence
-- Both are non-destructive shape changes; verified upstream that each OLD block appears exactly once.

DO $migration$
DECLARE
  v_src    text;
  v_new    text;
  v_header_old text;
  v_header_new text;
  v_body_old   text;
  v_body_new   text;
  v_header_hits int;
  v_body_hits   int;
BEGIN
  -- Current function source
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'compose_weekly_cpr_html';

  -- OLD header sequence: Cost | Total | Paid | Modified | Next Wk
  v_header_old :=
    E'    || ''<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Cost</th>''\n'
 || E'    || ''<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Total</th>''\n'
 || E'    || ''<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Paid</th>''\n'
 || E'    || ''<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Modified</th>''\n'
 || E'    || ''<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Next Wk</th>''';

  -- NEW header sequence: Modified | Cost | Total | Paid | Next Wk
  v_header_new :=
    E'    || ''<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Modified</th>''\n'
 || E'    || ''<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Cost</th>''\n'
 || E'    || ''<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Total</th>''\n'
 || E'    || ''<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Paid</th>''\n'
 || E'    || ''<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Next Wk</th>''';

  -- OLD body sequence: cost | total | paid | modified | owed
  v_body_old :=
    E'    || ''<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">'' || r.cost::text      || ''</td>''\n'
 || E'    || ''<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">'' || r.total::text     || ''</td>''\n'
 || E'    || ''<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">'' || r.paid::text      || ''</td>''\n'
 || E'    || ''<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">'' || r.modified::text  || ''</td>''\n'
 || E'    || ''<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155;font-weight:700">'' || r.owed::text || ''</td>''';

  -- NEW body sequence: modified | cost | total | paid | owed
  v_body_new :=
    E'    || ''<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">'' || r.modified::text  || ''</td>''\n'
 || E'    || ''<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">'' || r.cost::text      || ''</td>''\n'
 || E'    || ''<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">'' || r.total::text     || ''</td>''\n'
 || E'    || ''<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">'' || r.paid::text      || ''</td>''\n'
 || E'    || ''<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155;font-weight:700">'' || r.owed::text || ''</td>''';

  -- Sanity: each OLD block must appear exactly once
  v_header_hits := (length(v_src) - length(replace(v_src, v_header_old, ''))) / GREATEST(length(v_header_old), 1);
  v_body_hits   := (length(v_src) - length(replace(v_src, v_body_old,   ''))) / GREATEST(length(v_body_old), 1);

  IF v_header_hits <> 1 THEN
    RAISE EXCEPTION 'Header anchor not unique: found % occurrences', v_header_hits;
  END IF;
  IF v_body_hits <> 1 THEN
    RAISE EXCEPTION 'Body anchor not unique: found % occurrences', v_body_hits;
  END IF;

  -- Apply both reorders
  v_new := replace(v_src, v_header_old, v_header_new);
  v_new := replace(v_new, v_body_old,   v_body_new);

  IF v_new = v_src THEN
    RAISE EXCEPTION 'No change after replacements';
  END IF;

  -- Re-execute the modified function definition
  EXECUTE v_new;

  RAISE NOTICE 'compose_weekly_cpr_html updated. Source length: % → %', length(v_src), length(v_new);
END
$migration$;
