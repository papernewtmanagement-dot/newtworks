-- role_fit_v5_8 (2026-08-18): the SJT experience-softening branch of
-- _newtworks_role_fit_core now reads total documented work months from
-- public.resume_experience_months(resume_analysis) instead of SUMming
-- roles[].tenure_months. The sum double-counted concurrent jobs (a musician
-- with a day job read as a 66-year career) and read undated roles as zero
-- months (a 7-year claims adjuster read as no experience). The helper counts
-- each calendar month once from the start/end dates the resume tenure
-- extractor now writes, and returns NULL for "unknown", which this branch
-- treats as no adjustment (multiplier 1.0) — exactly the pre-v5_6 behavior.
-- Nothing else in the formula changes; applied as an exact substring
-- replacement on the live function body so every other line is byte-identical.
DO $mig$
DECLARE
  v_def text;
  v_old_block text;
  v_new_block text;
  v_old_tag text := 'model_tag: role_fit_v5_7_fc_norm_keys_2026_08_14';
  v_new_tag text := 'model_tag: role_fit_v5_8_experience_overlap_aware_2026_08_18';
  v_old_doc text := 'from resume_analysis.qualifications.prior_similar_role.roles[].tenure_months
(sum across all listed roles, missing per-role tenure treated as 0). No
roles data at all -> multiplier 1.0 (no change from pre-v5.6 behavior,
never guesses).';
  v_new_doc text := 'via public.resume_experience_months(resume_analysis), which counts each
calendar month once across the start/end dates the resume tenure extractor
writes on every role (concurrent jobs are not double-counted; older
hand-written roles with no start date add their tenure_months) and returns
NULL when no role carries usable tenure. NULL -> multiplier 1.0 (no change
from pre-v5.6 behavior, never guesses; "undated" is unknown, not zero).
Changed in role_fit_v5_8 (2026-08-18) from a plain SUM of tenure_months,
which double-counted overlapping roles and read undated roles as 0.';
BEGIN
  SELECT pg_get_functiondef('public._newtworks_role_fit_core'::regproc) INTO v_def;

  v_old_block := $b$      -- Experience-informed weight softening (does not touch v_value/score itself)
      IF jsonb_typeof(p_candidate.resume_analysis->'qualifications'->'prior_similar_role'->'roles') = 'array'
         AND jsonb_array_length(p_candidate.resume_analysis->'qualifications'->'prior_similar_role'->'roles') > 0 THEN
        SELECT COALESCE(SUM(COALESCE((role->>'tenure_months')::numeric, 0)), 0) INTO v_exp_months
          FROM jsonb_array_elements(p_candidate.resume_analysis->'qualifications'->'prior_similar_role'->'roles') AS role;
        v_exp_mult := LEAST(1.0, 0.5 + 0.5 * LEAST(v_exp_months, 24) / 24.0);
      ELSE
        v_exp_months := NULL;
        v_exp_mult := 1.0;
      END IF;
$b$;
  v_new_block := $b$      -- Experience-informed weight softening (does not touch v_value/score itself).
      -- v5_8: total months come from public.resume_experience_months, which
      -- counts each calendar month once across overlapping roles (start/end
      -- dates written by the resume tenure extractor) and returns NULL when
      -- no role carries usable tenure. NULL means "unknown", never zero.
      v_exp_months := public.resume_experience_months(p_candidate.resume_analysis);
      IF v_exp_months IS NULL THEN
        v_exp_mult := 1.0;
      ELSE
        v_exp_mult := LEAST(1.0, 0.5 + 0.5 * LEAST(v_exp_months, 24) / 24.0);
      END IF;
$b$;

  IF (length(v_def) - length(replace(v_def, v_old_block, ''))) / length(v_old_block) <> 1 THEN
    RAISE EXCEPTION 'role_fit_v5_8: expected exactly one occurrence of the old SJT block';
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old_tag, ''))) / length(v_old_tag) <> 1 THEN
    RAISE EXCEPTION 'role_fit_v5_8: expected exactly one occurrence of the old model_tag';
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old_doc, ''))) / length(v_old_doc) <> 1 THEN
    RAISE EXCEPTION 'role_fit_v5_8: expected exactly one occurrence of the old doc paragraph';
  END IF;

  v_def := replace(v_def, v_old_block, v_new_block);
  v_def := replace(v_def, v_old_tag, v_new_tag);
  v_def := replace(v_def, v_old_doc, v_new_doc);
  EXECUTE v_def;
END
$mig$;
