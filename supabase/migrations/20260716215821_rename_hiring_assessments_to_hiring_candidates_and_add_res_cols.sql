-- Step 1: add new columns before rename (constraints validated on existing data)
ALTER TABLE public.hiring_assessments
  ADD COLUMN IF NOT EXISTS res_nature smallint,
  ADD COLUMN IF NOT EXISTS res_nurture smallint,
  ADD COLUMN IF NOT EXISTS res_drivers smallint,
  ADD COLUMN IF NOT EXISTS resume_extracted_text text,
  ADD COLUMN IF NOT EXISTS resume_analysis text;

ALTER TABLE public.hiring_assessments
  ADD CONSTRAINT res_nature_range  CHECK (res_nature  IS NULL OR (res_nature  BETWEEN 1 AND 10)),
  ADD CONSTRAINT res_nurture_range CHECK (res_nurture IS NULL OR (res_nurture BETWEEN 1 AND 10)),
  ADD CONSTRAINT res_drivers_range CHECK (res_drivers IS NULL OR (res_drivers BETWEEN 1 AND 10));

-- Step 2: rename table
ALTER TABLE public.hiring_assessments RENAME TO hiring_candidates;

-- Step 3: rename RLS policies for clarity
ALTER POLICY staff_assessments_select ON public.hiring_candidates RENAME TO staff_hiring_candidates_select;
ALTER POLICY team_assessments_auth_write ON public.hiring_candidates RENAME TO team_hiring_candidates_auth_write;

-- Step 4: rewrite all 12 functions referencing the old table name; patch three-construct RESUME layer
DO $do$
DECLARE
    r record;
    v_def text;
    v_old_resume text := E'  -- RESUME layer\n  IF v_ta.resume_quality IS NOT NULL THEN\n    v_nr  := v_ta.resume_quality::numeric;\n    v_nur := v_ta.resume_quality::numeric;\n    v_dr  := v_ta.resume_quality::numeric;\n    v_dims_scored := v_dims_scored + 1;\n  END IF;';
    v_new_resume text := E'  -- RESUME layer (each construct scored independently 1-10)\n  IF v_ta.res_nature IS NOT NULL THEN v_nr := v_ta.res_nature::numeric; v_dims_scored := v_dims_scored + 1; END IF;\n  IF v_ta.res_nurture IS NOT NULL THEN v_nur := v_ta.res_nurture::numeric; END IF;\n  IF v_ta.res_drivers IS NOT NULL THEN v_dr := v_ta.res_drivers::numeric; END IF;\n  -- Legacy fallback: single-number resume_quality applied uniformly if new cols not scored yet\n  IF v_nr IS NULL AND v_ta.resume_quality IS NOT NULL THEN\n    v_nr := v_ta.resume_quality::numeric;\n    v_nur := v_ta.resume_quality::numeric;\n    v_dr := v_ta.resume_quality::numeric;\n    v_dims_scored := v_dims_scored + 1;\n  END IF;';
BEGIN
    FOR r IN
        SELECT p.proname, pg_get_functiondef(p.oid) AS body
        FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='public' AND prosrc ILIKE '%hiring_assessments%'
    LOOP
        v_def := replace(r.body, 'public.hiring_assessments', 'public.hiring_candidates');
        IF r.proname = 'hiregauge_three_construct_verdict' THEN
            v_def := replace(v_def, v_old_resume, v_new_resume);
        END IF;
        EXECUTE v_def;
    END LOOP;
END
$do$;

-- Step 5: verify no function bodies still reference the old name
DO $verify$
DECLARE
    v_leftover int;
BEGIN
    SELECT COUNT(*) INTO v_leftover
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND prosrc ILIKE '%hiring_assessments%';
    IF v_leftover > 0 THEN
        RAISE EXCEPTION 'Migration incomplete: % function(s) still reference hiring_assessments', v_leftover;
    END IF;
END
$verify$;;