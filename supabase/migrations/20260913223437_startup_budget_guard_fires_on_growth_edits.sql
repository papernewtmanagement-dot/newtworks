CREATE OR REPLACE FUNCTION public.guard_startup_memory_budget()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_rows  int;
  v_chars bigint;
  v_verb  text;
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

  -- Total budget. Checked on INSERT, on promotion (false -> true), and ALSO when an
  -- already-true row GROWS. Before 2026-09-13 the growth case was not checked, so edits to
  -- existing startup rows drifted the table past its own cap unnoticed (measured 33,064 / 32,000).
  -- Shrinking edits stay allowed even while over cap, so the table can always be brought back down.
  IF TG_OP = 'INSERT'
     OR OLD.load_at_startup IS DISTINCT FROM TRUE
     OR length(coalesce(NEW.content, '')) > length(coalesce(OLD.content, '')) THEN

    SELECT count(*), coalesce(sum(length(content)), 0)
      INTO v_rows, v_chars
      FROM public.persistent_memory
     WHERE agency_id = NEW.agency_id
       AND load_at_startup = true
       AND id <> NEW.id;

    IF v_rows + 1 > c_max_rows
       OR v_chars + length(coalesce(NEW.content, '')) > c_max_total_chars THEN

      v_verb := CASE
                  WHEN TG_OP = 'INSERT' OR OLD.load_at_startup IS DISTINCT FROM TRUE
                    THEN 'promotion'
                  ELSE 'this edit'
                END;

      RAISE EXCEPTION USING
        errcode = 'P0001',
        message = format(
          'Startup memory budget exceeded: %s would make %s rows / %s chars (budget %s rows / %s chars). Default is load_at_startup=false — system-specific and situational rows stay false. To proceed anyway: demote or trim another startup row first (one-in-one-out), or get Peter''s explicit approval and SET LOCAL app.startup_budget_override = ''peter_approved'' in the same transaction. See op-rule "Startup memory budget — hard cap enforced by trigger".',
          v_verb, v_rows + 1, v_chars + length(coalesce(NEW.content, '')), c_max_rows, c_max_total_chars);
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;
