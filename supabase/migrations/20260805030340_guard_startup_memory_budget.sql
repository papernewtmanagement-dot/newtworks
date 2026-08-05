-- Startup memory budget guard (2026-08-04)
-- Prevents re-inflation of load_at_startup=true rows in persistent_memory.
-- Budget: 18 rows / 32,000 total chars per agency; 6,000 chars per startup row.
-- Override (requires Peter's explicit approval in-conversation first):
--   SET LOCAL app.startup_budget_override = 'peter_approved';  -- same transaction as the write

CREATE OR REPLACE FUNCTION public.guard_startup_memory_budget()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_rows  int;
  v_chars bigint;
  c_max_rows       constant int := 18;
  c_max_total_chars constant int := 32000;
  c_max_row_chars   constant int := 6000;
BEGIN
  -- Only guard rows that are (or are becoming) startup rows
  IF NEW.load_at_startup IS NOT TRUE THEN
    RETURN NEW;
  END IF;

  -- Explicit, deliberate override — only after Peter approves in conversation
  IF coalesce(current_setting('app.startup_budget_override', true), '') = 'peter_approved' THEN
    RETURN NEW;
  END IF;

  -- Per-row cap: startup rows are guards, terminology, and constants — not reference docs.
  IF length(coalesce(NEW.content, '')) > c_max_row_chars THEN
    RAISE EXCEPTION USING
      errcode = 'P0001',
      message = format(
        'Startup-row size cap: this row is %s chars; startup rows max %s. Reference material belongs at load_at_startup=false (pulled on demand). If this row truly must load every chat, get Peter''s explicit approval, then SET LOCAL app.startup_budget_override = ''peter_approved'' in the same transaction. See op-rule "Startup memory budget — hard cap enforced by trigger".',
        length(coalesce(NEW.content, '')), c_max_row_chars);
  END IF;

  -- Total budget: checked only when a row is being promoted (INSERT as true, or false->true)
  IF TG_OP = 'INSERT' OR OLD.load_at_startup IS DISTINCT FROM TRUE THEN
    SELECT count(*), coalesce(sum(length(content)), 0)
      INTO v_rows, v_chars
      FROM public.persistent_memory
     WHERE agency_id = NEW.agency_id
       AND load_at_startup = true
       AND id <> NEW.id;

    IF v_rows + 1 > c_max_rows
       OR v_chars + length(coalesce(NEW.content, '')) > c_max_total_chars THEN
      RAISE EXCEPTION USING
        errcode = 'P0001',
        message = format(
          'Startup memory budget exceeded: promotion would make %s rows / %s chars (budget %s rows / %s chars). Default is load_at_startup=false — system-specific and situational rows stay false. To promote anyway: demote another startup row first (one-in-one-out), or get Peter''s explicit approval and SET LOCAL app.startup_budget_override = ''peter_approved'' in the same transaction. See op-rule "Startup memory budget — hard cap enforced by trigger".',
          v_rows + 1, v_chars + length(coalesce(NEW.content, '')), c_max_rows, c_max_total_chars);
    END IF;
  END IF;

  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_guard_startup_memory_budget ON public.persistent_memory;
CREATE TRIGGER trg_guard_startup_memory_budget
  BEFORE INSERT OR UPDATE ON public.persistent_memory
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_startup_memory_budget();
