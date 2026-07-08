-- Handbook restructure — signature+flatten+pay-integration
-- 2026-07-04

-- (a) Replace old "03 Bonuses & Pay" content with merged residual-pool design + retained elements.
-- Content payload elided here for readability; applied via Supabase MCP apply_migration in same session.
-- Retained: referral bonus, apparel, Champions Circle, application/premium glossary, ECRM tracking rule.
-- Dropped: obsolete weekly-pay mechanics, chargebacks passthrough, $10 bumps, base advance adjustments, manager bonus %, shadow-point UM math.

-- (b) Delete standalone residual-pool page (per Peter directive 2026-07-04)
DELETE FROM public.handbook
WHERE id = '6c08f83b-898b-4225-9b81-206362406e1c';

-- (c) Flatten: all sections under Handbook wrapper (confluence_page_id=296943645) become top-level
UPDATE public.handbook
SET parent_page_id = NULL,
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND parent_page_id = '296943645';

-- (d) Rename wrapper → clear signature-only role
UPDATE public.handbook
SET title = 'Signature Page',
    updated_at = NOW()
WHERE id = 'a3aa61c7-3c81-404c-80de-8f85944f18b1';

-- (e) Add sort_order column so signature can be forced to the bottom regardless of alphabetics
ALTER TABLE public.handbook
  ADD COLUMN IF NOT EXISTS sort_order INTEGER;

-- (f) Signature to the very bottom
UPDATE public.handbook
SET sort_order = 9999
WHERE id = 'a3aa61c7-3c81-404c-80de-8f85944f18b1';
