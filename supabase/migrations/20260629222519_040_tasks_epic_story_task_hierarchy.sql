-- Three-level hierarchy on public.tasks: Epic -> Story -> Task
-- Epic = big body of work (weeks/months)
-- Story = bucket-level unit of value (days)
-- Task = concrete action (hours)
--
-- task_type column drives the level. parent_task_id links child to parent.
-- Existing 47 rows default to 'task' and get re-typed via UI later.

-- 1) task_type column
ALTER TABLE public.tasks
  ADD COLUMN IF NOT EXISTS task_type text NOT NULL DEFAULT 'task';

ALTER TABLE public.tasks
  DROP CONSTRAINT IF EXISTS tasks_task_type_check;

ALTER TABLE public.tasks
  ADD CONSTRAINT tasks_task_type_check
  CHECK (task_type IN ('epic', 'story', 'task'));

-- 2) parent_task_id self-referencing FK
--    ON DELETE SET NULL: deleting a parent orphans children rather than cascade-wiping work.
ALTER TABLE public.tasks
  ADD COLUMN IF NOT EXISTS parent_task_id uuid
  REFERENCES public.tasks(id) ON DELETE SET NULL;

-- 3) Hierarchy integrity: epics can't have a parent.
--    Story/Task hierarchy beyond that is UI-enforced for v1.
ALTER TABLE public.tasks
  DROP CONSTRAINT IF EXISTS tasks_epic_no_parent_check;

ALTER TABLE public.tasks
  ADD CONSTRAINT tasks_epic_no_parent_check
  CHECK (task_type != 'epic' OR parent_task_id IS NULL);

-- 4) Prevent a task being its own parent (self-loop)
ALTER TABLE public.tasks
  DROP CONSTRAINT IF EXISTS tasks_no_self_parent_check;

ALTER TABLE public.tasks
  ADD CONSTRAINT tasks_no_self_parent_check
  CHECK (id != parent_task_id);

-- 5) Indexes for hierarchy lookup and type filtering
CREATE INDEX IF NOT EXISTS idx_tasks_parent_task_id
  ON public.tasks(parent_task_id)
  WHERE parent_task_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_tasks_task_type
  ON public.tasks(task_type);

-- 6) Helper view: tasks with parent title + epic ancestor for UI/queries
CREATE OR REPLACE VIEW public.v_tasks_with_hierarchy AS
WITH RECURSIVE ancestors AS (
  -- Anchor: every task points to itself as starting point
  SELECT
    id,
    id AS root_id,
    parent_task_id,
    task_type,
    0 AS depth
  FROM public.tasks
  UNION ALL
  -- Walk up to find the epic ancestor
  SELECT
    a.id,
    t.id AS root_id,
    t.parent_task_id,
    t.task_type,
    a.depth + 1
  FROM ancestors a
  JOIN public.tasks t ON t.id = a.parent_task_id
  WHERE a.depth < 5  -- guard against accidental cycles
)
SELECT
  t.*,
  p.title AS parent_title,
  p.task_type AS parent_task_type,
  (SELECT root_id FROM ancestors a WHERE a.id = t.id AND a.task_type = 'epic' LIMIT 1) AS epic_ancestor_id
FROM public.tasks t
LEFT JOIN public.tasks p ON p.id = t.parent_task_id;
