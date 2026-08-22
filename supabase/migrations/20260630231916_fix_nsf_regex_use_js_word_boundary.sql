-- Correct the previous fix: doc-processor classifier.ts uses JavaScript `new RegExp(...)`,
-- which recognizes `\b` (not Postgres's `\y`) as word boundary. Python `re` module also
-- recognizes `\b`. So the canonical cross-engine word boundary is `\b`.
UPDATE public.gl_classification_rules
SET match_payee_regex = '\bNSF\b|\bOVERDRAFT\b'
WHERE id = 'bc567ce7-a762-40e3-92e6-97697165e6ae';
