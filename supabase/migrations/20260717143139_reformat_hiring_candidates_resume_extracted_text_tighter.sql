-- Revert to backup, then reapply with tighter header rule (known headers only,
-- no generic ALL-CAPS fallback). Fixes false-positive dividers mid-content in
-- Anthony Vela's resume (all-caps body wrapping).

-- Step 1: restore from backup
UPDATE public.hiring_candidates h
SET resume_extracted_text = b.resume_extracted_text
FROM public._bak_hiring_candidates_resume_text_2026_07_17 b
WHERE h.id = b.id
  AND h.agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- Step 2: tightened reformatter
CREATE OR REPLACE FUNCTION public._resume_reformat_add_separators(input_text text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    cleaned text;
    lines text[];
    line text;
    trimmed text;
    trimmed_nocolon text;
    lower_trimmed text;
    output_lines text[] := ARRAY[]::text[];
    first_nonempty_seen boolean := false;
    is_header boolean;
    divider constant text := '────────────────────────────────────────';
    known_headers constant text[] := ARRAY[
        'objective', 'career objective',
        'summary', 'professional summary', 'profile', 'profile summary', 'about me',
        'experience', 'work experience', 'professional experience',
        'employment history', 'relevant experience', 'work history',
        'skills', 'skills & abilities', 'skills & competencies', 'skills and competencies',
        'skills and abilities', 'technical skills', 'technical proficiencies',
        'core competencies', 'expertise', 'key skills',
        'key skills and characteristics', 'areas of strength', 'courses & skills',
        'education', 'educational background', 'education/professional development',
        'education & credentials',
        'certifications', 'licenses', 'certifications & licenses',
        'certifications and licenses', 'licenses & certifications',
        'languages', 'language',
        'references', 'awards', 'honors', 'awards & recognition',
        'projects', 'volunteer experience', 'activities',
        'assessments', 'contact', 'contacts', 'contact information',
        'interests', 'hobbies', 'publications', 'affiliations',
        'key achievements', 'achievements', 'additional information',
        'professional development'
    ];
    idx integer;
    blank_run integer := 0;
    collapsed text[] := ARRAY[]::text[];
    result text;
BEGIN
    IF input_text IS NULL OR btrim(input_text) = '' THEN
        RETURN input_text;
    END IF;

    -- Fix extraction artifacts
    cleaned := replace(input_text, E'\\n', E'\n');
    cleaned := replace(cleaned, '(cid:127)', '•');
    cleaned := replace(cleaned, '(cid:129)', '•');
    cleaned := replace(cleaned, '(cid:9679)', '●');

    lines := regexp_split_to_array(cleaned, E'\n');

    FOR idx IN 1 .. array_length(lines, 1) LOOP
        line := lines[idx];
        trimmed := btrim(line);

        IF NOT first_nonempty_seen AND trimmed <> '' THEN
            first_nonempty_seen := true;
            output_lines := output_lines || line;
            CONTINUE;
        END IF;

        -- Header detection: known-headers only. No generic ALL-CAPS fallback.
        is_header := false;
        IF trimmed <> '' AND length(trimmed) <= 60 THEN
            trimmed_nocolon := btrim(rtrim(trimmed, ':'));
            lower_trimmed := lower(trimmed_nocolon);
            IF lower_trimmed = ANY(known_headers) THEN
                is_header := true;
            END IF;
        END IF;

        IF is_header THEN
            WHILE array_length(output_lines, 1) IS NOT NULL
              AND btrim(output_lines[array_length(output_lines, 1)]) = ''
            LOOP
                output_lines := output_lines[1 : array_length(output_lines, 1) - 1];
            END LOOP;

            output_lines := output_lines || ''::text;
            output_lines := output_lines || divider;
            output_lines := output_lines || ''::text;
            output_lines := output_lines || btrim(rtrim(trimmed, ':'));
        ELSE
            output_lines := output_lines || line;
        END IF;
    END LOOP;

    blank_run := 0;
    FOR idx IN 1 .. COALESCE(array_length(output_lines, 1), 0) LOOP
        IF btrim(output_lines[idx]) = '' THEN
            blank_run := blank_run + 1;
            IF blank_run <= 2 THEN
                collapsed := collapsed || output_lines[idx];
            END IF;
        ELSE
            blank_run := 0;
            collapsed := collapsed || output_lines[idx];
        END IF;
    END LOOP;

    result := btrim(array_to_string(collapsed, E'\n'), E'\n') || E'\n';
    RETURN result;
END;
$$;

-- Step 3: apply
UPDATE public.hiring_candidates
SET resume_extracted_text = public._resume_reformat_add_separators(resume_extracted_text)
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND resume_extracted_text IS NOT NULL
  AND btrim(resume_extracted_text) <> '';;