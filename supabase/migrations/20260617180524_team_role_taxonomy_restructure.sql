-- Drop old CHECK constraints (legacy 'staff_*' names)
ALTER TABLE team DROP CONSTRAINT IF EXISTS staff_role_check;
ALTER TABLE team DROP CONSTRAINT IF EXISTS staff_role_level_check;

-- Add new role_category column
ALTER TABLE team ADD COLUMN IF NOT EXISTS role_category text;

-- Peter: role 'Owner' -> 'Escalation' (role_level stays 'Owner')
UPDATE team SET role = 'Escalation'
WHERE first_name = 'Peter' AND last_name = 'Story';

-- Leslie: role/role_level Support -> NULL (category stays 'admin')
UPDATE team SET role = NULL, role_level = NULL
WHERE first_name = 'Leslie' AND last_name = 'Jones';

-- Inez (archived): role 'Support' -> NULL
UPDATE team SET role = NULL
WHERE first_name = 'Inez' AND last_name = 'Garcia';

-- Backfill role_category from role
UPDATE team SET role_category = 'Sales'
WHERE role IN ('Acquisition', 'Inside Sales');

UPDATE team SET role_category = 'Retention'
WHERE role IN ('Reception', 'Escalation');

-- Re-add CHECK constraints with new values (renamed to team_* prefix)
ALTER TABLE team ADD CONSTRAINT team_role_check
  CHECK (role IS NULL OR role IN (
    'Acquisition', 'Inside Sales', 'Reception', 'Escalation'
  ));

ALTER TABLE team ADD CONSTRAINT team_role_level_check
  CHECK (role_level IS NULL OR role_level IN (
    'Owner', 'Office Manager', 'Unit Manager', 'Section Manager',
    'Account Manager', 'Account Associate'
  ));

ALTER TABLE team ADD CONSTRAINT team_role_category_check
  CHECK (role_category IS NULL OR role_category IN ('Sales', 'Retention'));
