-- finrebuild_f6_statement_gl_writer_recipe_wrapper
-- run_internal_recipe dynamically calls public.<internal_handler>(agency_id,
-- recipe_id) -- a 2-arg wrapper matching that exact calling convention,
-- same pattern as the existing bank_gl_writer/cc_gl_writer/payroll_gl_writer
-- wrappers. Full-history dry run/backfill still available via the 5-arg form.
CREATE OR REPLACE FUNCTION public.statement_gl_writer(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN public.statement_gl_writer(p_agency_id, NULL::uuid, NULL::date, NULL::date, FALSE);
END;
$function$;

-- Recipe migration: "Bank GL Writer" (id 10bf585e-0cbe-4071-bdbb-38e5f14b5282,
-- cron 30 11 * * * America/Chicago) repointed to statement_gl_writer,
-- renamed "Statement GL Writer" -- covers both bank and credit statements
-- now that both read from the unified statements table.
-- "Credit Card GL Writer" (id 194265c1-1a47-42c7-9a33-6de9bbac57f9, cron
-- 45 11 * * * America/Chicago) deactivated -- merged into the above.
UPDATE public.automation_recipes
SET internal_handler = 'statement_gl_writer', recipe_name = 'Statement GL Writer',
    recipe_description = 'Classifies statements rows into ledger (replaces Bank GL Writer + Credit Card GL Writer, 2026-08-08 finance rebuild)'
WHERE id = '10bf585e-0cbe-4071-bdbb-38e5f14b5282';

UPDATE public.automation_recipes
SET is_active = false,
    recipe_description = COALESCE(recipe_description,'') || ' [deactivated 2026-08-08: merged into Statement GL Writer]'
WHERE id = '194265c1-1a47-42c7-9a33-6de9bbac57f9';

-- finrebuild_f7_drop_retired_writers_and_suspense_fns
-- Phase 3.4: drop bank_gl_writer and cc_gl_writer (replaced by
-- statement_gl_writer; both recipe rows already repointed/deactivated above).
-- Phase 3.5: drop check_suspense_aging and classify_je_via_chat -- no
-- suspense account and no chat-classification path exist in the new
-- design (D3). Verified zero live callers (functions, edge functions,
-- automation recipes) before dropping.
DROP FUNCTION IF EXISTS public.bank_gl_writer(uuid, boolean);
DROP FUNCTION IF EXISTS public.bank_gl_writer(uuid, uuid);
DROP FUNCTION IF EXISTS public.cc_gl_writer(uuid, boolean);
DROP FUNCTION IF EXISTS public.cc_gl_writer(uuid, uuid);
DROP FUNCTION IF EXISTS public.check_suspense_aging(uuid);
DROP FUNCTION IF EXISTS public.classify_je_via_chat(uuid, uuid, text, text, text, boolean, text, integer, text, text, text, text, text);
