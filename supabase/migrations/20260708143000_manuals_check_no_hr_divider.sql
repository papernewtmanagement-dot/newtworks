-- Guardrail: reject any manuals.content containing a line consisting solely of `---`.
-- Matches at content start, end, or between newlines. Markdown table separators (`| --- |`)
-- are inside pipes so they don't match.
-- Origin: 2026-07-08. Peter's explicit rule ("never use horizontal rule to separate sections")
-- was previously ignored by a Claude session that ran a regexp_replace inserting 428 dividers
-- across 87 pages. This constraint enforces the rule at the DB layer where session drift
-- cannot bypass it.

ALTER TABLE public.manuals
  ADD CONSTRAINT manuals_no_hr_divider
  CHECK (content !~ E'(^|\n)---(\n|$)');

COMMENT ON CONSTRAINT manuals_no_hr_divider ON public.manuals IS
  'Blocks standalone --- horizontal rules in manuals content. Markdown table separators (| --- |) pass because they are inside pipes. Rule origin: op-rule "Manuals Rulebook" section structure_and_dividers.';
