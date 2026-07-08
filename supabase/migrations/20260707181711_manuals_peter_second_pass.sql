-- 20260707181711_manuals_peter_second_pass

-- Case-sensitive so lowercase "peter" in email addresses / URL slugs stays intact.
-- Match case in output so all-caps contexts stay all-caps.

-- Handbook
UPDATE public.handbook
SET content = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                content,
                'PETER''S',  'THE AGENT''S'),
                'PETER',     'THE AGENT'),
                'Peter''s',  'the agent''s'),
                'Peter',     'the agent'),
                'peter.story.yrru@statefarm.com', '___EMAIL_PRESERVE___peter.story.yrru@statefarm.com___EMAIL_PRESERVE___'),
    title = REPLACE(REPLACE(REPLACE(REPLACE(
                title,
                'PETER''S', 'THE AGENT''S'),
                'PETER',    'THE AGENT'),
                'Peter''s', 'the agent''s'),
                'Peter',    'the agent')
WHERE is_active = true
  AND (content ~ '(Peter|PETER)' OR title ~ '(Peter|PETER)');

-- unwind the email marker (belt & suspenders: lowercase "peter" wouldn't have matched anyway, but leaving no artifacts)
UPDATE public.handbook
SET content = REPLACE(content, '___EMAIL_PRESERVE___', '')
WHERE content LIKE '%___EMAIL_PRESERVE___%';

-- Processes
UPDATE public.processes
SET content = REPLACE(REPLACE(REPLACE(REPLACE(
                content,
                'PETER''S', 'THE AGENT''S'),
                'PETER',    'THE AGENT'),
                'Peter''s', 'the agent''s'),
                'Peter',    'the agent'),
    title = REPLACE(REPLACE(REPLACE(REPLACE(
                title,
                'PETER''S', 'THE AGENT''S'),
                'PETER',    'THE AGENT'),
                'Peter''s', 'the agent''s'),
                'Peter',    'the agent')
WHERE is_active = true
  AND (content ~ '(Peter|PETER)' OR title ~ '(Peter|PETER)');

-- Admin pages
UPDATE public.admin_pages
SET content = REPLACE(REPLACE(REPLACE(REPLACE(
                content,
                'PETER''S', 'THE AGENT''S'),
                'PETER',    'THE AGENT'),
                'Peter''s', 'the agent''s'),
                'Peter',    'the agent'),
    title = REPLACE(REPLACE(REPLACE(REPLACE(
                title,
                'PETER''S', 'THE AGENT''S'),
                'PETER',    'THE AGENT'),
                'Peter''s', 'the agent''s'),
                'Peter',    'the agent')
WHERE is_active = true
  AND (content ~ '(Peter|PETER)' OR title ~ '(Peter|PETER)');
