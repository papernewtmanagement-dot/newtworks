-- Kill the cutover gate in all 4 GL writers by rewriting the fallback date.
-- Writers still read gl_cutover_date from settings, but if setting missing (or set way in past),
-- v_cutover_date resolves to 1900-01-01 → no real transaction is ever "before cutover".
-- Followed by DELETE of the settings themselves.

DO $$
DECLARE
  v_fn text;
  v_def text;
BEGIN
  FOR v_fn IN
    SELECT proname
    FROM pg_proc
    WHERE pronamespace = 'public'::regnamespace
      AND proname IN ('bank_gl_writer','cc_gl_writer','gl_entry_writer','payroll_gl_writer')
  LOOP
    -- Iterate all overloads of this function
    FOR v_def IN
      SELECT pg_get_functiondef(p.oid)
      FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace
        AND p.proname = v_fn
        AND position('v_cutover_date := ''2026-05-01''::date' IN pg_get_functiondef(p.oid)) > 0
    LOOP
      v_def := replace(v_def, '2026-05-01', '1900-01-01');
      EXECUTE v_def;
    END LOOP;
  END LOOP;
END $$;

-- Delete cutover-gate setting
DELETE FROM public.settings
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  AND setting_key = 'gl_cutover_date';

-- Reset "[pre-cutover; no JE posted per accounting_rules]" on skipped bank txns so they're re-eligible
UPDATE public.bank_transactions
SET posted_at = NULL,
    notes = replace(replace(notes, ' [pre-cutover; no JE posted per accounting_rules]', ''),
                   '[pre-cutover; no JE posted per accounting_rules]', '')
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  AND notes ILIKE '%pre-cutover%'
  AND journal_entry_id IS NULL;

-- Same for credit
UPDATE public.credit_transactions
SET posted_at = NULL,
    notes = replace(replace(notes, ' [pre-cutover; no JE posted per accounting_rules]', ''),
                   '[pre-cutover; no JE posted per accounting_rules]', '')
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  AND notes ILIKE '%pre-cutover%'
  AND journal_entry_id IS NULL;
