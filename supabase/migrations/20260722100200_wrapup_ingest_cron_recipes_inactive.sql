-- Stages the two new wrap-up ingest cron recipes to Peter's spec, INACTIVE.
-- Row A: Fri 3:00, 3:30, 4:00, 4:30, 5:00, 5:30, 6:00, 6:30 PM CT (8 fires)
-- Row B: Fri 7:00 PM CT (via Sat 00:00 UTC) + Sat 8:00 AM/1:00 PM/6:00 PM CT (4 fires)
--
-- BOTH require Peter's explicit approval before is_active=true. Cron expressions
-- are DST-correct for CDT (UTC-5); during CST winter, UTC hours need +1 shift OR
-- runtime DST guard. Companion function apply_ct_cron_dst_sync() currently only
-- covers 3 recipes (payroll_weekly_nag, pfa_monthly_nag, dispatch_payroll_email_parser);
-- extend it to include these two new handlers before winter, or accept 1-hour drift.
--
-- Prior paused row 7f240d43 (cron 13,43 * * * * — wrong cadence) kept as
-- zzz_PAUSED archive per convention. Do not reactivate.

INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
  composio_action, internal_handler, input_config, is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Weekly Wrapup Ingest — Friday PM',
  'Wrap-up ingest — Fri 3:00, 3:30, 4:00, 4:30, 5:00, 5:30, 6:00, 6:30 PM CT (8 fires). Runs document-processor mode=wrapup: Gmail fetch, sender/week resolve, LLM organize into six-item rubric, upsert weekly_cpr_team_detail.wrapup_text, hash-throttled nag send on missing items. Cron 0,30 20-23 * * 5 UTC is DST-correct (UTC-5, CDT). During CST winter shift UTC hours +1 OR add runtime DST guard. Companion Fri 7 PM + Sat recipe covers 7 PM CT via Sat 00:00 UTC. Rebuilt 2026-07-22 replacing paused 7f240d43. is_active flip requires Peter approval.',
  'cron',
  '0,30 20-23 * * 5',
  'INTERNAL',
  'dispatch_document_processor',
  '{"mode":"wrapup"}'::jsonb,
  false
);

INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
  composio_action, internal_handler, input_config, is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Weekly Wrapup Ingest — Fri 7 PM + Saturday windows',
  'Wrap-up ingest — Fri 7:00 PM CT + Sat 8:00 AM/1:00 PM/6:00 PM CT (4 fires). Runs document-processor mode=wrapup. Cron 0 0,13,18,23 * * 6 UTC: Sat 00:00 UTC = Fri 7 PM CT (last Fri fire, absorbs into Sat DOW), Sat 13:00 UTC = 8 AM CT, Sat 18:00 UTC = 1 PM CT, Sat 23:00 UTC = 6 PM CT. DST-correct for CDT. During CST winter shift UTC hours +1 OR runtime DST guard. is_active flip requires Peter approval.',
  'cron',
  '0 0,13,18,23 * * 6',
  'INTERNAL',
  'dispatch_document_processor',
  '{"mode":"wrapup"}'::jsonb,
  false
);
