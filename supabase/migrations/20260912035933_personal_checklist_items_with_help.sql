-- The Daily Wrap-up page also carried the PERSONAL items. checklist_items_for_week
-- filters to scope='team', so these rows are invisible to the daily team list and
-- to the CPR team-miss audit — they exist so the Checklist tab can show each
-- person their own items with the same explanations, and the page can then go.
-- Item 25 (end-of-day and end-of-week emails) is deliberately absent: Code Reds
-- are now code_flags and the weekly wrap-up is the Checklist tab itself.
INSERT INTO public.checklist_items (agency_id, item_key, title, scope, sort_order, effective_from, help_text)
VALUES
('126794dd-25ff-47d2-a436-724499733365', 'checkins', 'Activity check-ins answered, 3x daily', 'personal', 10, '2026-09-12',
$h$Three windows every workday: start of day, after lunch, and 5 PM.

Reply with the day's dials, quotes, and sales points. Missing a check-in is a Code Red.$h$),

('126794dd-25ff-47d2-a436-724499733365', 'inbox', 'Inbox worked, 3x daily', 'personal', 20, '2026-09-12',
$h$Once per window (start of day, after lunch, 5 PM):

- **Customer-related emails** → moved to the right Shared Outlook Folder (Customers, P&C, L&H, Billing, and so on)
- **Everything else** → moved to a personal subfolder or deleted
- **Peter's and Marie's emails** → answered (any one of the three windows is fine)

Example: a customer asks for an ID card → move it to the Customers shared folder right away. Fire underwriting sends a replacement-cost mismatch note on a new home → move it to P&C right away.$h$),

('126794dd-25ff-47d2-a436-724499733365', 'scorecards', 'Conversation scorecards and recordings turned in', 'personal', 30, '2026-09-12',
$h$Scorecards ride on the entry you log. The cadence ramps with tenure — the canonical schedule is on the Your Path handbook page:

- Weeks 1-8: scorecard and record every conversation
- Weeks 9-13: scorecard and record every quote or review
- Weeks 14 and on: scorecard at end of day and record one quote or review

Grading is x / 1 / 2 / 3. x means it did not come up. 1 means you spoke words and that's about it. 2 means you did it well but it did not land. 3 means you did it well and it landed.

Missing a required scorecard is a Code Red.$h$),

('126794dd-25ff-47d2-a436-724499733365', 'ecrm_accurate', 'Today''s conversations recorded in ECRM', 'personal', 40, '2026-09-12',
$h$Every conversation, log, and task from today lives in ECRM by end of day, and paper notes get disposed of once that's true.

**During the day: work from a To-Dos file on your desktop.**

- Keep a plain text file called **To-Dos** open all day.
- Log notes into it as conversations happen — customer name, phone number, what they need, next step, and any detail a teammate would need to pick it up cold.
- **Ctrl+S every few seconds** so nothing is lost to a crash or reboot.
- At every natural opportunity, move those notes into ECRM as logs on the account, or as tasks on the opportunity, case, policy, or claim.

**At wrap: everything from To-Dos is in ECRM.** By end of day the file is empty of anything not yet in ECRM, with enough detail that anyone can pick it up cold.

**Once ECRM is complete: dispose of paper notes.** Customer notes are shredded immediately if any customer information is on them. Agency notes are shredded if you are working remote, reused if you are in the office.

If ECRM was slow, the shared drive was down, or you got pulled away mid-call, the To-Dos file is what makes sure nothing is lost.$h$),

('126794dd-25ff-47d2-a436-724499733365', 'whiteboard', 'Today''s activity logged on the Dashboard', 'personal', 50, '2026-09-12',
$h$Most items flow over from ECRM on their own. What you log by hand: credit cards, referrals, and reviews.

Referrals: the person referred and the person who referred them. Reviews: who wrote it and which website.$h$),

('126794dd-25ff-47d2-a436-724499733365', 'ooo', 'Out-of-office notifications set', 'personal', 60, '2026-09-12',
$h$Sign up when you are heading out.

Out-of-office text response on when you leave for the day. Out-of-office email response on when you leave for the week.$h$)
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.personal_checklist_items(p_week_ending date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_week_end date;
BEGIN
  v_week_end := COALESCE(p_week_ending, v_today + (6 - EXTRACT(DOW FROM v_today)::int));
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object('id', i.id, 'title', i.title,
                                        'help_text', i.help_text, 'help_excerpt_id', i.help_excerpt_id)
           ORDER BY i.sort_order, i.title)
    FROM public.checklist_items i
    WHERE i.agency_id = v_agency AND i.scope = 'personal'
      AND i.effective_from <= v_week_end
      AND (i.effective_to IS NULL OR i.effective_to >= v_week_end)
  ), '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.personal_checklist_items(date) TO authenticated, service_role;
