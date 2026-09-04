-- Late Pay Process: recurring payment is forced on the THIRD late pay (Peter, 2026-09-04).
--
-- The restored talk tracks forced recurring monthly payment on the second late
-- pay, and the first-time warning promised it would be required "if you're late
-- again" (i.e. the second). Peter's ruling is the third. Two lines move:
--   first time  — the refusal warning stops promising it next time
--   second time — stops forcing, pushes hard and warns that a third makes it
--                 mandatory; the meet-with-Peter alternative is unchanged
-- The third-time block already forced it and is untouched.

DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_old text;
  v_new text;
BEGIN
  SELECT content INTO v_old FROM manuals
   WHERE agency_id = v_agency AND confluence_page_id = '1912274945';
  IF v_old IS NULL THEN RAISE EXCEPTION 'Late Pay Process row not found'; END IF;

  -- First time: the warning pointed at the very next late pay.
  v_new := replace(v_old,
    'if you’re late again, we will require it.}}',
    'if this keeps happening, we will require it.}}');
  IF v_new = v_old THEN RAISE EXCEPTION 'first-time warning anchor not found'; END IF;
  v_old := v_new;

  -- Second time: push, do not force.
  v_new := replace(v_old,
    E'- Force RecMo, {{say: Peter is requiring it so you don''t get slammed with late fees.}}\n- If they refuse, {{say: The only alternative is to meet with Peter',
    E'- Push RecMo hard, {{say: Peter is asking you to put this on automatic payment so you don''t get slammed with late fees.}}\n- If they refuse, warn them: {{say: Ok. But if this happens one more time, we''ll have to require it.}}\n- Then offer the alternative, {{say: The other option is to meet with Peter');
  IF v_new = v_old THEN RAISE EXCEPTION 'second-time block anchor not found'; END IF;

  UPDATE manuals SET content = v_new, updated_at = now()
   WHERE agency_id = v_agency AND confluence_page_id = '1912274945';
END $$;
