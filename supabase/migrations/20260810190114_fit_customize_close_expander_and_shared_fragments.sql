-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-10 19:01:14 UTC (ledger name: fit_customize_close_expander_and_shared_fragments) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260810190114.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- 1. New shared fragment: the one-simple-price rule, nested
INSERT INTO public.manuals (agency_id, manual_type, title, content, content_format, is_active)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'excerpt', 'One Simple Price',
$frag$- Always show only one simple total price for everything discussed
  - If the customer asks to break it down, you can do that, but bring it back to one simple price
$frag$, 'markdown', true
WHERE NOT EXISTS (
  SELECT 1 FROM public.manuals
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND lower(trim(title))='one simple price'
);

-- 2. New shared fragment: the great-fit-check expander, body pulls Customize Step
INSERT INTO public.manuals (agency_id, manual_type, title, content, content_format, is_active)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'excerpt', 'Great Fit Check',
$frag$<details>
<summary>{{say: Now, this is either a great fit for you or we need to customize it more. So is this a terrible fit for you?}} 🙊</summary>

*[Embedded excerpt from: Customize Step]*

</details>
$frag$, 'markdown', true
WHERE NOT EXISTS (
  SELECT 1 FROM public.manuals
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND lower(trim(title))='great fit check'
);

-- 3. Customize Step trimmed to the expander BODY only.
--    Price lines moved to "One Simple Price"; the great-fit line is now the
--    expander summary inside "Great Fit Check". Nesting matches Confluence 2124251137.
UPDATE public.manuals SET content = $frag$If they don’t feel it’s a GREAT fit:

- {{say: If it’s not a GREAT fit, I think we need to customize it some more}}
- {{say: Remember that insurance is all about transferring risk}}
- {{say: We’re taking on}} <ALL/MOST> {{say: of the risk right now--let’s give some of it back and lower the cost for you}}
- {{say: What risks do you feel comfortable taking back on yourself?}} 🙊
- If they aren’t sure, bail them out:
  - {{say: I might have some suggestions for you}}
  - Order of things to edit:
    - Coverages first:
      - Deductibles
      - Less catastrophic coverages
      - Coverages/endorsements they seemed to be comfortable removing
  - FINALLY, if nothing else works, policies:
    - In order of catastrophic consequences:
      - PAP
      - PLUP
      - Home/Renters
      - HI
      - DI
      - Life
    - Policies they seemed to be comfortable removing

Repeat this process until they say it’s a great fit.
$frag$, version = version + 1, updated_at = now()
WHERE id = 'b1185a41-5a2c-4481-a4b9-50e01ea7be97';

-- 4. FIT Closer: drop its hand-built <details> wrapper in favour of the shared
--    fragment, and surface the one-simple-price rule above the total-price line.
UPDATE public.manuals SET content = replace(
  replace(content,
    $old$<details>
<summary>Now, this is either a great fit for you or we need to customize it more. So is this a terrible fit for you? 🙊</summary>

*[Embedded excerpt from: Customize Step]*

</details>$old$,
    $new$*[Embedded excerpt from: Great Fit Check]*$new$),
  $old2$*[Embedded excerpt from: Customize Header]*

{{say: Ok, so with all of the options$old2$,
  $new2$*[Embedded excerpt from: Customize Header]*

*[Embedded excerpt from: One Simple Price]*

{{say: Ok, so with all of the options$new2$),
version = version + 1, updated_at = now()
WHERE id = '7ef39c69-8164-44b6-83c9-0162d8245600';
