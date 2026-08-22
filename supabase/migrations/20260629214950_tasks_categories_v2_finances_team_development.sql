-- 1. Drop existing CHECK constraint
ALTER TABLE public.tasks DROP CONSTRAINT IF EXISTS tasks_task_category_check;

-- 2. Rename existing 'training' rows to 'team_development'
UPDATE public.tasks SET task_category='team_development'
WHERE task_category='training';

-- 3. Re-categorize: 12 admin → finances
UPDATE public.tasks SET task_category='finances'
WHERE id IN (
  '11a574a9-02f7-44fb-afb0-3b3317d21339', -- Confirm comp_recap mapping with Marie
  '23476026-c56a-4d16-9ffb-ff6036b39ef2', -- Set up monthly bank statement forward workflow
  '0a6bee04-4656-4332-9d64-f4ab106778ee', -- Peter: confirm status of COA-001
  '0d8c85e8-302a-4d3f-9f3f-ae181450fa71', -- Peter: confirm status + opening balance of COA-013
  '0440fbe8-e4a6-474e-8b12-9756145af045', -- Roll back [SAMPLE] codings
  '7d2f70f4-98fb-461a-aca6-3f825fdc27f1', -- Confirm CC last-4 to legacy-source card mapping
  '6ac16fa1-b3f6-4fa6-983d-baa2b2e8c24f', -- Provide 4/30/26 bank statement balances
  '4c4f7aa5-e61d-4f41-93a4-c8f99ff2ae40', -- Personal-card / legacy accounts
  'b20c15ea-826a-4c64-ab9f-77fc59d3ae8a', -- 0005 PERSONAL $120K review
  'eb16cd20-3aaa-41e9-bf4e-5d35be3fa0f1', -- Producer Production Reports (feeds AIPP)
  '29bd6d79-0f32-4d29-acd1-a792654021f1', -- 2025 SurePayroll reports
  'acbac6b8-eaf9-4a14-9717-18c30efaf235'  -- Thomas Lynch VA tax residency
);

-- 4. Assign the held NULL task to team_development
UPDATE public.tasks SET task_category='team_development'
WHERE id='b7b4b244-983d-4ab6-b14f-2ec0fdc60683';

-- 5. Add new CHECK constraint with 7 values (training removed, team_development + finances added)
ALTER TABLE public.tasks
  ADD CONSTRAINT tasks_task_category_check
  CHECK (task_category IS NULL OR task_category IN (
    'web_app','admin','marketing','team_development','handbook','playbook','finances'
  ));
