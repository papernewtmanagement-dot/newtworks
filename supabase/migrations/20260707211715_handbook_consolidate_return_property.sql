-- 20260707211715_handbook_consolidate_return_property

-- Employment & Termination: add alarm-code deletion to the return-property statement
UPDATE public.handbook
SET content = REPLACE(
  content,
  'Team members are required to return all property of State Farm or the agency immediately on termination, including but not limited to computers, keys, forms, manuals, and any other items provided to the team member.',
  'Team members are required to return all property of State Farm or the agency immediately on termination, including but not limited to computers, keys, forms, manuals, and any other items provided to the team member. Alarm codes are deleted by the agent immediately on termination.'
)
WHERE title = 'Employment & Termination';

-- Health, Safety, & Security: remove the termination sentence (now consolidated on Employment & Termination)
UPDATE public.handbook
SET content = REPLACE(
  content,
  'Team members are given keys and a personal alarm code after successfully completing one month of full time employment. Team members are required to notify the agent immediately if a key is lost. Duplicate keys should never be made. Alarm codes should never be shared. Immediately upon termination, team members must return their keys, and their alarm codes will be deleted by the agent.',
  'Team members are given keys and a personal alarm code after successfully completing one month of full time employment. Team members are required to notify the agent immediately if a key is lost. Duplicate keys should never be made. Alarm codes should never be shared. See the Employment & Termination page for the property-return procedure on separation.'
)
WHERE title = 'Health, Safety, & Security';
