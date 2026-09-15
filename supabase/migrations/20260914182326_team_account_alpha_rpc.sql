-- Feeds the {{alpha-split}} page host on the Checklists manual page so the
-- account alphabet split is read from team.account_alpha instead of being typed
-- into the page. Peter 2026-09-14, after John's departure left "John: A-K"
-- sitting in the manual.
CREATE OR REPLACE FUNCTION public.team_account_alpha()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'team_member_id', t.id,
        'name', COALESCE(NULLIF(TRIM(t.nickname), ''), t.first_name),
        'full_name', TRIM(t.first_name || ' ' || COALESCE(t.last_name, '')),
        'account_alpha', t.account_alpha
      )
      ORDER BY t.account_alpha
    ),
    '[]'::jsonb
  )
  FROM public.team t
  WHERE t.is_active
    AND t.account_alpha IS NOT NULL
    AND TRIM(t.account_alpha) <> '';
$fn$;

GRANT EXECUTE ON FUNCTION public.team_account_alpha() TO authenticated;
