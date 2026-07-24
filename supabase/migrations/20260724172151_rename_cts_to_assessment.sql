-- Migration: rename all cts_ / _cts_ hiring-framework functions to assessment_ / _assessment_.
-- Atomic: creates new funcs (with body substitution), rewrites 10 consumers, GRANTs, drops old.

DO $mig$
DECLARE r record;
        v_def text;
        v_helpers_order text[] := ARRAY[
          '_cts_reliability_confidence',
          '_cts_apply_reliability_confidence',
          '_cts_distortion_severity',
          '_cts_dampen_trait_by_distortion',
          '_cts_role_fit_contrib',
          '_cts_role_fit_gates',
          '_cts_role_fit_apply_gates'
        ];
        v_os_order text[] := ARRAY[
          'cts_all_competencies',
          'cts_aspirant_os',
          'cts_sales_outbound_os',
          'cts_sales_inbound_os',
          'cts_sales_in_book_os',
          'cts_retention_reception_os',
          'cts_retention_escalation_os',
          'cts_retention_support_os'
        ];
        v_name text;
BEGIN
  FOR r IN
    SELECT p.oid FROM pg_proc p
      JOIN pg_namespace n ON n.oid=p.pronamespace
      JOIN pg_language l ON l.oid=p.prolang
    WHERE n.nspname='public' AND l.lanname='plpgsql' AND p.proname ~ '^cts_'
  LOOP
    v_def := pg_get_functiondef(r.oid);
    v_def := regexp_replace(v_def, 'FUNCTION public\.cts_', 'FUNCTION public.assessment_');
    v_def := regexp_replace(v_def, 'public\._cts_', 'public._assessment_', 'g');
    v_def := regexp_replace(v_def, 'public\.cts_',  'public.assessment_',  'g');
    v_def := regexp_replace(v_def, '\y_cts_',       '_assessment_',        'g');
    v_def := regexp_replace(v_def, '\ycts_',        'assessment_',         'g');
    EXECUTE v_def;
  END LOOP;

  FOREACH v_name IN ARRAY v_helpers_order LOOP
    FOR r IN
      SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname = v_name
    LOOP
      v_def := pg_get_functiondef(r.oid);
      v_def := regexp_replace(v_def, 'FUNCTION public\._cts_', 'FUNCTION public._assessment_');
      v_def := regexp_replace(v_def, 'public\._cts_', 'public._assessment_', 'g');
      v_def := regexp_replace(v_def, 'public\.cts_',  'public.assessment_',  'g');
      v_def := regexp_replace(v_def, '\y_cts_',       '_assessment_',        'g');
      v_def := regexp_replace(v_def, '\ycts_',        'assessment_',         'g');
      EXECUTE v_def;
    END LOOP;
  END LOOP;

  FOREACH v_name IN ARRAY v_os_order LOOP
    FOR r IN
      SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname = v_name
    LOOP
      v_def := pg_get_functiondef(r.oid);
      v_def := regexp_replace(v_def, 'FUNCTION public\.cts_', 'FUNCTION public.assessment_');
      v_def := regexp_replace(v_def, 'public\._cts_', 'public._assessment_', 'g');
      v_def := regexp_replace(v_def, 'public\.cts_',  'public.assessment_',  'g');
      v_def := regexp_replace(v_def, '\y_cts_',       '_assessment_',        'g');
      v_def := regexp_replace(v_def, '\ycts_',        'assessment_',         'g');
      EXECUTE v_def;
    END LOOP;
  END LOOP;
END $mig$;

-- Rewrite 10 consumer bodies
DO $mig$
DECLARE r record;
        v_def text;
        v_consumers text[] := ARRAY[
          '_hiregauge_get_trait_value',
          'assessment_nature',
          'assessment_role_fit_aspirant',
          'assessment_role_fit_retention_escalation',
          'assessment_role_fit_retention_reception',
          'assessment_role_fit_retention_support',
          'assessment_role_fit_sales_in_book',
          'assessment_role_fit_sales_inbound',
          'assessment_role_fit_sales_outbound',
          'verdict_overall'
        ];
        v_name text;
BEGIN
  FOREACH v_name IN ARRAY v_consumers LOOP
    FOR r IN
      SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname = v_name
    LOOP
      v_def := pg_get_functiondef(r.oid);
      v_def := regexp_replace(v_def, 'public\._cts_', 'public._assessment_', 'g');
      v_def := regexp_replace(v_def, 'public\.cts_',  'public.assessment_',  'g');
      v_def := regexp_replace(v_def, '\y_cts_',       '_assessment_',        'g');
      v_def := regexp_replace(v_def, '\ycts_',        'assessment_',         'g');
      EXECUTE v_def;
    END LOOP;
  END LOOP;
END $mig$;

-- Grants matching prior cts_ grants
DO $mig$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname, pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname ~ '^_?assessment_'
      AND p.proname NOT IN (
        'assessment_nature',
        'assessment_role_fit_aspirant',
        'assessment_role_fit_retention_escalation',
        'assessment_role_fit_retention_reception',
        'assessment_role_fit_retention_support',
        'assessment_role_fit_sales_in_book',
        'assessment_role_fit_sales_inbound',
        'assessment_role_fit_sales_outbound'
      )
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(%s) TO anon, authenticated, service_role',
                   r.proname, r.args);
  END LOOP;
END $mig$;

-- Drop old cts_ / _cts_ family
DROP FUNCTION IF EXISTS public.cts_all_competencies(uuid);
DROP FUNCTION IF EXISTS public.cts_aspirant_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);
DROP FUNCTION IF EXISTS public.cts_sales_outbound_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);
DROP FUNCTION IF EXISTS public.cts_sales_inbound_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);
DROP FUNCTION IF EXISTS public.cts_sales_in_book_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);
DROP FUNCTION IF EXISTS public.cts_retention_reception_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);
DROP FUNCTION IF EXISTS public.cts_retention_escalation_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);
DROP FUNCTION IF EXISTS public.cts_retention_support_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);

DROP FUNCTION IF EXISTS public.cts_best_fit_role(uuid);

DO $mig$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname ~ '^cts_competency_'
  LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS public.%I(%s)', r.proname, r.args);
  END LOOP;
END $mig$;

DROP FUNCTION IF EXISTS public._cts_role_fit_apply_gates(uuid,text,numeric,numeric,text,numeric);
DROP FUNCTION IF EXISTS public._cts_role_fit_gates(uuid);
DROP FUNCTION IF EXISTS public._cts_role_fit_contrib(numeric,numeric,boolean);
DROP FUNCTION IF EXISTS public._cts_dampen_trait_by_distortion(integer,text,text);
DROP FUNCTION IF EXISTS public._cts_distortion_severity(text);
DROP FUNCTION IF EXISTS public._cts_apply_reliability_confidence(integer,text);
DROP FUNCTION IF EXISTS public._cts_reliability_confidence(text);

-- Sanity
DO $mig$
DECLARE v_count int;
BEGIN
  SELECT count(*) INTO v_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname ~ '^_?cts_';
  IF v_count > 0 THEN
    RAISE EXCEPTION 'sanity: % cts_ functions still present after rename', v_count;
  END IF;

  SELECT count(*) INTO v_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND (pg_get_functiondef(p.oid) ~ '\ypublic\._?cts_'
      OR pg_get_functiondef(p.oid) ~ '\y_?cts_\w+\s*\(');
  IF v_count > 0 THEN
    RAISE EXCEPTION 'sanity: % function bodies still call cts_/_cts_ names', v_count;
  END IF;
END $mig$;
