-- The nightly 'Statement GL Writer' automation calls its internal_handler as
-- <name>(agency_id, recipe_id). With internal_handler = 'statement_gl_writer', that
-- call matched TWO functions: the thin recipe wrapper (uuid, uuid) and the main writer
-- (uuid, uuid, date, date, boolean) whose trailing four parameters carry defaults.
-- Postgres refused with 'function public.statement_gl_writer(uuid, uuid) is not unique'
-- and the automation has failed every night since 2026-08-08.
--
-- Defaults cannot be stripped from the main writer without dropping and rebuilding it,
-- which is not worth the risk on a financial writer. Instead the wrapper gets its own
-- unambiguous name and the recipe is repointed at it. The main writer is untouched.

CREATE OR REPLACE FUNCTION public.statement_gl_writer_recipe(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  RETURN public.statement_gl_writer(p_agency_id, NULL::uuid, NULL::date, NULL::date, FALSE);
END;
$function$;

DROP FUNCTION IF EXISTS public.statement_gl_writer(uuid, uuid);

UPDATE public.automation_recipes
SET internal_handler = 'statement_gl_writer_recipe',
    recipe_description = 'Classifies statements rows into ledger. Replaces Bank GL Writer + Credit Card GL Writer (2026-08-08 finance rebuild). Handler renamed 2026-08-09 to resolve an ambiguous-overload failure.',
    input_config = jsonb_build_object(
      'description', 'Calls public.statement_gl_writer_recipe(agency_id, recipe_id), which posts any unposted statements rows into ledger.'
    ),
    output_config = jsonb_build_object(
      'output_table', 'ledger',
      'resolution_waterfall', 'skip rules -> category match -> classification rules -> balance-sheet guard -> entity Unclassified'
    ),
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND recipe_name = 'Statement GL Writer';
