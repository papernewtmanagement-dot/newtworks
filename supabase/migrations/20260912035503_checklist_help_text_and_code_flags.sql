-- 1) Help text on every checklist item, lifted from the Daily Wrap-up
--    processes page so that page can be deleted without losing anything.
--    Three items are explained by excerpt pages that live on their own and
--    stay authoritative; those point at the excerpt instead of copying it.
ALTER TABLE public.checklist_items ADD COLUMN IF NOT EXISTS help_text text;
ALTER TABLE public.checklist_items ADD COLUMN IF NOT EXISTS help_excerpt_id uuid;

UPDATE public.checklist_items SET help_excerpt_id = '5e95834b-1525-42b6-be12-539fc60b24a0' WHERE item_key = 'shared_folders' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';
UPDATE public.checklist_items SET help_excerpt_id = '1dd233e6-00c6-4a99-851c-89701d26a58c' WHERE item_key = 'texts' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';
UPDATE public.checklist_items SET help_excerpt_id = '7355573e-85d7-4fd9-8967-27bd1a15d147' WHERE item_key = 'appointments' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.checklist_items SET help_text = $h$**8:30 AM every weekday** — 30 minutes. Virtual, cameras on for role play. The leader rotates weekly.

Full rhythm lives on the Daily Kickoff page.$h$ WHERE item_key = 'kickoff' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.checklist_items SET help_text = $h$Mail gets opened, worked, and sent back out the same day it arrives. Policy packets are reused — the envelope the documents arrive in is the envelope they go to the customer in, so open it carefully.

**Life policies — 10x12 envelope, green markings on the sides**

1. Open the envelope carefully. It gets reused.
2. Remove the agent information pages — those do not go to the customer.
3. Look for an amendment of application. Signature page included → scan it and save the scan in the customer folder.
4. Put all customer pages back in the same envelope.
5. Write the customer address on a blank sheet of paper and place it so the address is visible through the envelope window.
6. Reseal the envelope and send it to the customer. No postage required.

In ECRM:
- Log "Life policy docs mailed to customer."
- No amendment included → note that in the log.
- Signature required → note that the signature page is scanned in the customer folder, and set a follow-up task for whoever sold the policy.

**Other policy documents — large envelope, blue markings**

Medicare supplement and similar policies. Signature pages are not typically included.

1. Open the envelope carefully.
2. Remove any agent pages.
3. Address the envelope the same way as above — customer address on a blank sheet, visible through the window.
4. Reseal and send. No postage required.

In ECRM: log that the policy documents were mailed out.

**Mortgagee update letters**

1. Scan the letter and save it to the customer folder.
2. Create a task for service to update the applicable policy according to the letter.$h$ WHERE item_key = 'mail' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.checklist_items SET help_text = $h$Verify every claim has a CLAIM touch task (CLAIM T1, CLAIM T2, or CLAIM T3).

Verify every claim is marked as REVIEWED.$h$ WHERE item_key = 'claims' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.checklist_items SET help_text = $h$**Opportunity Lists** cover opportunities in the **New**, **Assigned**, and **Not Now Follow-Up** stages — including brand-new leads from SF.com, State-to-State, Outlook folders, Events, and Telemarketer as they land in ECRM. By rule, these opportunities don't carry ECRM sales tasks — they're worked through the cadence-driven lists on the *Lead Process page instead.

Make sure all lists on the *Lead Process page are set up in ECRM.

Work each list every day. All cleared by end of day.$h$ WHERE item_key = 'opp_lists' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.checklist_items SET help_text = $h$Opportunities and customers with no usable phone number.

Set the list up on the *Lead Process page in ECRM. Work it every day. All cleared by end of day.$h$ WHERE item_key = 'missing_phone' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.checklist_items SET help_text = $h$Opportunities and customers flagged with missing or bad data.

Set the list up on the *Lead Process page in ECRM. Work it every day. All cleared by end of day.$h$ WHERE item_key = 'missing_data' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.checklist_items SET help_text = $h$**Sales tasks** are ECRM tasks on opportunities in the **Quoting stage or beyond**. Different from the Opportunity Lists, which cover earlier-stage opportunities and don't carry sales tasks by rule.

Remember your sales funnel: 100 household sales touches → 20 quote offers → 5 H3Os presented → 1 household sale, 1 review, 1 referral, and 1/3 of a life policy.

Priority order for your daily sales work:
- Brand new leads that just came in (ILPs, SF.com, Telemarketer, Events)
- Already presented — need to **close**
- Need to present a **quote**
- Other follow-up sales tasks
- Opportunity Lists (see *Lead Process)
- **Corporate** created lists of existing customers (including Winbacks)
- **Personally** created lists of existing customers$h$ WHERE item_key = 'sales_tasks' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.checklist_items SET help_text = $h$Every opportunity in an active stage carries an open ECRM task, so nothing sits with no next step.

Exception: opportunities in **New**, **Assigned**, and **Not Now Follow-Up** are worked through the Opportunity Lists and do not carry tasks by rule.

Check the no-follow-up-task list every day. Anything on it either gets a task or gets moved to the right stage.$h$ WHERE item_key = 'opp_has_task' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.checklist_items SET help_text = $h$Turn campaign leads into opportunities. Converting a lead to an opportunity removes it from the campaign's list, which is how you clear the campaign.

**Do NOT delete a campaign when its list hits zero.** We use zeroed-out campaign lists as our memory of which lists we've already built — that's how we tell what still needs to be created. Deleting the campaign erases that record.$h$ WHERE item_key = 'campaign_leads' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.checklist_items SET help_text = $h$**Once a month (setup):** Retention creates this campaign at the start of each month, listing every customer billed in the previous month.

**Every day thereafter (daily work):** Work the campaign down. Verify every customer on it has an SC Review task for auto and home policies. Retention owns the task creation and follow-through.$h$ WHERE item_key = 'billed_prior_month' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.checklist_items SET help_text = $h$Required fields filled on successful first contact; set follow-up tasks OR set the stage to Not Now Follow-Up (see *Lead Process).

Complete records keep the pipeline reportable and prevent handoffs from stalling.$h$ WHERE item_key = 'ecrm_required_fields' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.checklist_items SET help_text = $h$Every submitted app needs its case opened so nothing falls through the gap between sale and issued policy.

- **Where to find the list:** home dashboard → scroll to the bottom → the link is on the left. It shows every new household from this year that doesn't yet have an onboarding case. Get cases created for all of them.
- **Work it every day — no lag.** Being a week behind means people get confused and end up dinged. Has to be up to date.
- **Edge case — it's actually an existing customer, not new business:** the opportunity is mis-classified. Set it to existing business (or winback if applicable). The list takes a day or two to catch up, so check it again the next day.
- **Edge case — case created but customer still on the list:** they have more than one new-business opportunity. Close the extras, keeping the one the case was created through. The list takes a day or two to catch up.$h$ WHERE item_key = 'ecrm_onboarding_cases' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.checklist_items SET help_text = $h$Close a case once no open tasks remain.

Open cases with zero pending tasks clutter the queue and hide the ones that actually need work.$h$ WHERE item_key = 'ecrm_cases_closed' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.checklist_items SET help_text = $h$If we have a dedicated service person, it should be RARE that anyone has more than FIVE service tasks:
- Many "service" tasks might actually be sales — check the label
- Almost all TRUE service tasks should be assigned to Retention
- That leaves you with only a couple per day

Handle through text when possible.

Outbound calls to handle these MUST be scheduled. Scheduled times 15 minutes or less, and we always tell the customer we have 10 minutes (5-minute buffer).$h$ WHERE item_key = 'service_tasks' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.checklist_items SET help_text = $h$**Production Manager** is a section within ECRM (the screen you check) — not a role.

**Part 1 — Policies not routed to ECRM:**
- Select start and end date (Monday = include the weekend)
- Sort descending on "Created By"
- Look for records starting with INT or Q&B
- Verify each has an ECRM task
- Verify contact info is accurate; TruePeople if no phone number
- Send Peter the list with confirmation that ECRM tasks exist with correct contact info

**Part 2 — Stuck policies:**
- Filter for status **Ready for SFPP** and **Incomplete**
- Any policy stuck in these statuses needs immediate resolution (payment issue, missing document, etc.)
- Log resolution steps and follow up until cleared$h$ WHERE item_key = 'production_manager' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.checklist_items SET help_text = $h$At the end of the day, consolidate every customer premium payment received today (cash, checks, transfers) and take it to the Frost drive-through or mobile-deposit it.

Log each of those payments the same day on the Deposits tab — first name + last initial only, policy type, amount, and check number if applicable.

**Then hit Close Day on the Deposits tab.** This is the step that locks further entries for today and notifies the team via Telegram. If you skip it, the day sits open — nothing downstream fires and the monthly reconciliation to State Farm won't line up.

Peter is notified automatically on close and Newtworks handles the monthly reconciliation.$h$ WHERE item_key = 'deposits' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.checklist_items SET help_text = $h$Every resume that lands anywhere today — Indeed, ZipRecruiter, CareerPlug, direct email, walk-in — should reach **paper.newt.management@gmail.com**. Forwarding is automated on an hourly cadence; from there Newtworks reads it into the hiring pipeline.

At wrap, confirm today's submissions actually landed:
- Open the paper.newt.management inbox
- Filter to today's date
- Reconcile against the source dashboards (Indeed, ZipRecruiter, CareerPlug applicant list)

Any gap → forward the missing resumes manually into paper.newt.management, then flag the automation so the recipe can be inspected before the next run.

A resume that never reaches the inbox never enters the hiring pipeline.$h$ WHERE item_key = 'resumes' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.checklist_items SET help_text = $h$Every Do Not Call / Do Not Contact request received today (inbound phone, text, email, in-office, or opt-out reply from a campaign) needs to be worked before end of day:
- Log the request in the Internal Do Not Contact list
- Remove any active follow-up tasks on the opportunity or customer
- Cancel or suppress any scheduled outbound campaigns that would have touched that number
- Confirm suppression across channels — a phone opt-out that still gets a marketing text on Monday is a legal exposure

Opt-outs are honored immediately on the channel received; cross-channel suppression follows the same day. The Internal Do Not Contact list is the agency's primary defense in any dispute — an unworked list on Friday night is an unworked list all weekend.$h$ WHERE item_key = 'dnc' AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 2) Code Reds and Code Yellows, raised any day from the Checklist tab.
--    Replaces the daily Code Red email. Each flag is its own dated row; the
--    week's rows are rolled up into weekly_cpr_team_detail.code_reds /
--    code_yellows so the CPR reads them exactly as it does today.
CREATE TABLE IF NOT EXISTS public.code_flags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  team_member_id uuid NOT NULL REFERENCES public.team(id),
  flag_date date NOT NULL,
  severity text NOT NULL CHECK (severity IN ('red', 'yellow')),
  note text NOT NULL,
  correction text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_code_flags_member_date ON public.code_flags (agency_id, team_member_id, flag_date);

ALTER TABLE public.code_flags ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS code_flags_read ON public.code_flags;
CREATE POLICY code_flags_read ON public.code_flags FOR SELECT TO authenticated USING (true);

CREATE OR REPLACE FUNCTION public.code_flags_sync_week(p_agency_id uuid, p_team_member_id uuid, p_week_ending date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_report uuid;
  v_reds text;
  v_yellows text;
BEGIN
  SELECT r.id INTO v_report
  FROM public.weekly_cpr_reports r
  WHERE r.agency_id = p_agency_id AND r.week_ending_date = p_week_ending;
  IF v_report IS NULL THEN RETURN; END IF;

  SELECT string_agg(line, E'\n' ORDER BY line) INTO v_reds FROM (
    SELECT to_char(f.flag_date, 'Dy FMMon FMDD') || ' — ' || f.note
           || COALESCE(' (fix: ' || NULLIF(btrim(f.correction), '') || ')', '') AS line
    FROM public.code_flags f
    WHERE f.agency_id = p_agency_id AND f.team_member_id = p_team_member_id
      AND f.severity = 'red' AND f.flag_date BETWEEN p_week_ending - 6 AND p_week_ending
  ) s;

  SELECT string_agg(line, E'\n' ORDER BY line) INTO v_yellows FROM (
    SELECT to_char(f.flag_date, 'Dy FMMon FMDD') || ' — ' || f.note
           || COALESCE(' (fix: ' || NULLIF(btrim(f.correction), '') || ')', '') AS line
    FROM public.code_flags f
    WHERE f.agency_id = p_agency_id AND f.team_member_id = p_team_member_id
      AND f.severity = 'yellow' AND f.flag_date BETWEEN p_week_ending - 6 AND p_week_ending
  ) s;

  INSERT INTO public.weekly_cpr_team_detail (agency_id, weekly_cpr_report_id, team_member_id, code_reds, code_yellows, updated_at)
  VALUES (p_agency_id, v_report, p_team_member_id, COALESCE(v_reds, ''), COALESCE(v_yellows, ''), now())
  ON CONFLICT (weekly_cpr_report_id, team_member_id) DO UPDATE
  SET code_reds = EXCLUDED.code_reds, code_yellows = EXCLUDED.code_yellows, updated_at = now();
END;
$function$;

CREATE OR REPLACE FUNCTION public.code_flag_add(p_severity text, p_note text, p_correction text DEFAULT NULL, p_date date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_me uuid := public.current_team_member_id();
  v_agency uuid;
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_day date;
  v_id uuid;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'no team member for this login' USING ERRCODE = '42501'; END IF;
  IF p_severity NOT IN ('red', 'yellow') THEN RAISE EXCEPTION 'severity must be red or yellow' USING ERRCODE = '22023'; END IF;
  IF COALESCE(btrim(p_note), '') = '' THEN RAISE EXCEPTION 'say what happened' USING ERRCODE = '22023'; END IF;
  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = v_me;

  v_day := COALESCE(p_date, v_today);
  IF v_day > v_today OR v_day < v_today - 13 THEN
    RAISE EXCEPTION 'date must be within the last two weeks' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.code_flags (agency_id, team_member_id, flag_date, severity, note, correction)
  VALUES (v_agency, v_me, v_day, p_severity, btrim(p_note), NULLIF(btrim(p_correction), ''))
  RETURNING id INTO v_id;

  PERFORM public.code_flags_sync_week(v_agency, v_me, v_day + (6 - EXTRACT(DOW FROM v_day)::int));
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.code_flag_delete(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_me uuid := public.current_team_member_id();
  v_agency uuid;
  v_day date;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'no team member for this login' USING ERRCODE = '42501'; END IF;
  SELECT f.agency_id, f.flag_date INTO v_agency, v_day
  FROM public.code_flags f WHERE f.id = p_id AND f.team_member_id = v_me;
  IF v_day IS NULL THEN RAISE EXCEPTION 'not your flag' USING ERRCODE = '42501'; END IF;

  DELETE FROM public.code_flags WHERE id = p_id;
  PERFORM public.code_flags_sync_week(v_agency, v_me, v_day + (6 - EXTRACT(DOW FROM v_day)::int));
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.code_flags_mine(p_week_ending date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_me uuid := public.current_team_member_id();
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_week_end date;
BEGIN
  IF v_me IS NULL THEN RETURN '[]'::jsonb; END IF;
  v_week_end := COALESCE(p_week_ending, v_today + (6 - EXTRACT(DOW FROM v_today)::int));
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'id', f.id, 'flag_date', f.flag_date, 'severity', f.severity,
             'note', f.note, 'correction', f.correction)
           ORDER BY f.flag_date DESC, f.created_at DESC)
    FROM public.code_flags f
    WHERE f.team_member_id = v_me AND f.flag_date BETWEEN v_week_end - 6 AND v_week_end
  ), '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.code_flag_add(text, text, text, date) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.code_flag_delete(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.code_flags_mine(date) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.code_flags_sync_week(uuid, uuid, date) TO service_role;
