-- Adds a 'financials' manual_type and moves the Bookkeeping Process page into it.
-- Peter 2026-09-14: the page "moved" to the Financials P&L tab. Retyping it off
-- 'admin' takes it out of the Admin manual navigation (Manual.jsx MANUAL_CONFIG
-- has no 'financials' entry, so no manual renders it) and leaves the Financials
-- bookkeeping panel as its only home. One copy, one place.
-- parent_page_id cleared because its old parent ("Bookkeeping & Payroll",
-- newtworks-admin-bookkeeping) stays in the Admin manual.

ALTER TABLE public.manuals DROP CONSTRAINT IF EXISTS manuals_manual_type_check;

ALTER TABLE public.manuals ADD CONSTRAINT manuals_manual_type_check
  CHECK (manual_type = ANY (ARRAY[
    'handbook'::text,
    'processes'::text,
    'admin'::text,
    'roleplaying'::text,
    'financial_literacy'::text,
    'investments'::text,
    'excerpt'::text,
    'financials'::text
  ]));

UPDATE public.manuals
   SET manual_type    = 'financials',
       parent_page_id = NULL,
       sort_order     = 1
 WHERE id = '67d6c2a0-754a-49de-9cd5-764fe52bd5b0'
   AND agency_id = '126794dd-25ff-47d2-a436-724499733365';
