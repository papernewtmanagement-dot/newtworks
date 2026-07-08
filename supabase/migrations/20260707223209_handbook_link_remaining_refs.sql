-- 20260707223209_handbook_link_remaining_refs

-- Add anchor to Error Alert section on Winning & Learning
UPDATE public.handbook
SET content = REPLACE(
  content,
  '## Error Alert: Code Red/Code Yellow',
  '## <a id="error-alert-code-red-code-yellow"></a>Error Alert: Code Red/Code Yellow'
)
WHERE title = 'Winning & Learning';

-- Link the parenthesized reference in Getting Paid
UPDATE public.handbook
SET content = REPLACE(
  content,
  '(see the Winning & Learning page)',
  '(see the [Winning & Learning](/handbook/newtworks-native-handbook-04-winning) page)'
)
WHERE title = 'Getting Paid';

-- Link the same-page reference on Winning & Learning
UPDATE public.handbook
SET content = REPLACE(
  content,
  '(see the Error Alert: Code Red/Code Yellow section below)',
  '(see the [Error Alert: Code Red/Code Yellow](#error-alert-code-red-code-yellow) section below)'
)
WHERE title = 'Winning & Learning';
