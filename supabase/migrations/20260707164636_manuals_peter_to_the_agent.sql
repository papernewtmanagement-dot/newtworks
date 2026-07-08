-- 20260707164636_manuals_peter_to_the_agent

-- Replace "Peter Story" first so surname drops cleanly, then "Peter" standalone.
-- Case-sensitive on purpose: preserves email addresses containing lowercase "peter".

UPDATE public.handbook
SET content = REPLACE(REPLACE(content, 'Peter Story', 'the agent'), 'Peter', 'the agent'),
    title   = REPLACE(REPLACE(title,   'Peter Story', 'the agent'), 'Peter', 'the agent')
WHERE is_active = true
  AND (content LIKE '%Peter%' OR title LIKE '%Peter%');

UPDATE public.processes
SET content = REPLACE(REPLACE(content, 'Peter Story', 'the agent'), 'Peter', 'the agent'),
    title   = REPLACE(REPLACE(title,   'Peter Story', 'the agent'), 'Peter', 'the agent')
WHERE is_active = true
  AND (content LIKE '%Peter%' OR title LIKE '%Peter%');

UPDATE public.admin_pages
SET content = REPLACE(REPLACE(content, 'Peter Story', 'the agent'), 'Peter', 'the agent'),
    title   = REPLACE(REPLACE(title,   'Peter Story', 'the agent'), 'Peter', 'the agent')
WHERE is_active = true
  AND (content LIKE '%Peter%' OR title LIKE '%Peter%');
