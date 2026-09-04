-- Retention restructure, pass 2 (Peter, 2026-09-04).
--
-- 1. Late Pay Process: restore the first/second/third-time talk tracks that the
--    previous migration dropped. Peter's ruling covered the two conflicting
--    cadence tables, not the talk tracks; wording restored verbatim from the
--    Confluence source (page 1912274945, v3).
-- 2. Operations > Service Handling had three shell pages that were only a few
--    lines of mechanics wrapped around a script fragment — the same
--    script-vs-mechanics split the claims work collapsed:
--      Cancellation Process        → mechanics folded into the Save Household
--                                    fragment (embedded on Retention > Appointments)
--      Payment Processes           → "always use this script" folded into the
--                                    Inbound Calls fragment under Billing
--      Renewal Premium Change Proc → folded into Retention > Outbound Touches as
--                                    its own checklist item
--    All three rows are deleted; nothing referenced them by marker.

DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_old text;
  v_new text;
  v_mech text;
  v_n int;
BEGIN
  ------------------------------------------------------------------
  -- 0. Guards
  ------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM manuals
   WHERE agency_id = v_agency AND is_active
     AND (content ILIKE '%[Included from: Cancellation Process]%' OR content ILIKE '%[Embedded excerpt from: Cancellation Process]%'
       OR content ILIKE '%[Included from: Payment Processes]%' OR content ILIKE '%[Embedded excerpt from: Payment Processes]%'
       OR content ILIKE '%[Included from: Renewal Premium Change Process]%' OR content ILIKE '%[Embedded excerpt from: Renewal Premium Change Process]%');
  IF v_n <> 0 THEN RAISE EXCEPTION 'A page still references one of the shells being deleted (% rows)', v_n; END IF;

  ------------------------------------------------------------------
  -- 1. Late Pay Process — talk tracks back, under the rules.
  ------------------------------------------------------------------
  SELECT content INTO v_old FROM manuals WHERE agency_id = v_agency AND confluence_page_id = '1912274945';
  IF position(E'<details>\n<summary>Late Payment</summary>' IN v_old) = 0 THEN
    RAISE EXCEPTION 'Late Pay Process anchor not found';
  END IF;
  v_new := replace(v_old, E'<details>\n<summary>Late Payment</summary>', $c$**First time they’re late:**

- Get payment
- Warn about upcoming late fees and suggest solutions:
  - {{say: We will be charging late fees in the near future.}}
  - {{say: Best thing to do is to have it automatically pull payment each month. Also, you’ll want to meet with Peter now. He’ll walk you through how to avoid problems down the road and save lots of money on your insurance over the rest of your life. I can schedule that appointment now. Would you prefer in-office or virtual?}}
- If they refuse the RecMo or the appointment, warn them: {{say: Ok, but in order to protect you from getting slammed with late fees down the road, if you’re late again, we will require it.}}

**Second time they’re late:**

- Force RecMo, {{say: Peter is requiring it so you don't get slammed with late fees.}}
- If they refuse, {{say: The only alternative is to meet with Peter so he can help you save money and avoid problems down the road. Would you prefer virtual or in-office?}}

**Third time they’re late:**

- Force upfront payment
- Force recurring payment for the next renewal
- Schedule appointment with Peter: {{say: You’ll need to meet with Peter so he can help you save money and avoid problems down the road. Would you prefer virtual or in-office?}}

<details>
<summary>Late Payment</summary>$c$);
  UPDATE manuals SET content = v_new, updated_at = now()
   WHERE agency_id = v_agency AND confluence_page_id = '1912274945';

  ------------------------------------------------------------------
  -- 2a. Cancellation Process → Save Household
  ------------------------------------------------------------------
  SELECT content INTO v_mech FROM manuals WHERE agency_id = v_agency AND confluence_page_id = '932806995';
  v_mech := regexp_replace(v_mech, E'\\s*\\*\\[Embedded excerpt from: Save Household\\]\\*\\s*$', '');
  IF v_mech IS NULL OR length(v_mech) < 500 THEN RAISE EXCEPTION 'Cancellation Process mechanics look wrong (%)', length(v_mech); END IF;
  UPDATE manuals
     SET content = v_mech || E'\n\n' || content, updated_at = now()
   WHERE agency_id = v_agency AND confluence_page_id = '929464910' AND manual_type = 'excerpt';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 1 THEN RAISE EXCEPTION 'Save Household fragment not found'; END IF;
  DELETE FROM manuals WHERE agency_id = v_agency AND confluence_page_id = '932806995';

  ------------------------------------------------------------------
  -- 2b. Payment Processes → Inbound Calls (Billing)
  ------------------------------------------------------------------
  SELECT content INTO v_old FROM manuals WHERE agency_id = v_agency AND confluence_page_id = '864124937' AND manual_type = 'excerpt';
  IF position(E'### Sales, Added/Replaced Auto, Cancelations' IN v_old) = 0 THEN
    RAISE EXCEPTION 'Inbound Calls sales anchor not found';
  END IF;
  v_new := replace(v_old, E'### Sales, Added/Replaced Auto, Cancelations',
    E'<details>\n<summary>Taking a payment</summary>\n\nAlways use this script:\n\n*[Embedded excerpt from: Payment Script]*\n\n</details>\n\n### Sales, Added/Replaced Auto, Cancelations');
  UPDATE manuals SET content = v_new, updated_at = now()
   WHERE agency_id = v_agency AND confluence_page_id = '864124937' AND manual_type = 'excerpt';
  DELETE FROM manuals WHERE agency_id = v_agency AND confluence_page_id = '870351216';

  ------------------------------------------------------------------
  -- 2c. Renewal Premium Change Process → Outbound Touches
  ------------------------------------------------------------------
  SELECT content INTO v_old FROM manuals WHERE agency_id = v_agency AND confluence_page_id = 'newtworks-native-outbound-touches-2026-09-04';
  IF position(E'<details>\n<summary>Work late pays</summary>' IN v_old) = 0 THEN
    RAISE EXCEPTION 'Outbound Touches late-pay anchor not found';
  END IF;
  v_new := replace(v_old, E'<details>\n<summary>Work late pays</summary>',
    E'<details>\n<summary>Premium changes at renewal</summary>\n\nText them to prompt a callback.\n\nFollow the script:\n\n*[Embedded excerpt from: Premium Change Script]*\n\n</details>\n\n\n\n<details>\n<summary>Work late pays</summary>');
  UPDATE manuals SET content = v_new, updated_at = now()
   WHERE agency_id = v_agency AND confluence_page_id = 'newtworks-native-outbound-touches-2026-09-04';
  DELETE FROM manuals WHERE agency_id = v_agency AND confluence_page_id = '870351246';

  ------------------------------------------------------------------
  -- 2d. Service Handling contents list
  ------------------------------------------------------------------
  UPDATE manuals
     SET content = replace(replace(replace(content,
                     E'- Cancellation Process\n', ''),
                     E'- Payment Processes\n', ''),
                     E'- Renewal Premium Change Process', ''),
         updated_at = now()
   WHERE agency_id = v_agency AND confluence_page_id = '866811973';
  UPDATE manuals SET content = rtrim(content, E'\n ') WHERE agency_id = v_agency AND confluence_page_id = '866811973';
END $$;
