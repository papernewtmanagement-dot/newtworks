-- 1. Expand role_level vocabulary to include Support and Owner
ALTER TABLE public.staff
  DROP CONSTRAINT IF EXISTS staff_role_level_check;
ALTER TABLE public.staff
  ADD CONSTRAINT staff_role_level_check
  CHECK (role_level IS NULL OR role_level IN ('Account Manager','Account Associate','Support','Owner'));

-- 2. Role change for Jason
UPDATE public.staff
SET role = 'Acquisition', updated_at = NOW()
WHERE first_name = 'Jason' AND last_name = 'Fuller';

-- 3. Role-level assignments
UPDATE public.staff SET role_level = 'Owner',             updated_at = NOW() WHERE first_name = 'Peter'     AND last_name = 'Story';
UPDATE public.staff SET role_level = 'Account Manager',   updated_at = NOW() WHERE first_name = 'Thomas'    AND last_name = 'Lynch';
UPDATE public.staff SET role_level = 'Account Associate', updated_at = NOW() WHERE first_name = 'Cassandra' AND last_name = 'Alves';
UPDATE public.staff SET role_level = 'Account Associate', updated_at = NOW() WHERE first_name = 'Stephanie' AND last_name = 'Rogers';
UPDATE public.staff SET role_level = 'Support',           updated_at = NOW() WHERE first_name = 'Leslie'    AND last_name = 'Jones';
