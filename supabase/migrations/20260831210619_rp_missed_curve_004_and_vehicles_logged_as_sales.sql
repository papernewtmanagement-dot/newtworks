-- Peter 2026-08-31: reduction curve 0.08 -> 0.04, now that voicemails are in the missed count.
-- Total wipe moves from 35.4% missed to 50% missed. Typical week costs about 10% instead of 20%.
DO $mig$
DECLARE
  v_def text; n int;
  a1 CONSTANT text := 'LEAST(100, ROUND(0.08 * v_team_missed_pct * v_team_missed_pct, 2))';
  a2 CONSTANT text := '0.08 x missed%^2';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p JOIN pg_namespace nsp ON nsp.oid=p.pronamespace
  WHERE nsp.nspname='public' AND p.proname='compute_weekly_retention_points';
  IF v_def IS NULL THEN RAISE EXCEPTION 'function not found'; END IF;
  n := (length(v_def) - length(replace(v_def, a1, ''))) / length(a1);
  IF n <> 1 THEN RAISE EXCEPTION 'curve anchor matched % times', n; END IF;
  v_def := replace(v_def, a1, 'LEAST(100, ROUND(0.04 * v_team_missed_pct * v_team_missed_pct, 2))');
  v_def := replace(v_def, a2, '0.04 x missed%^2');
  EXECUTE v_def;
END $mig$;

COMMENT ON FUNCTION public.compute_weekly_retention_points(uuid, date) IS
  'Weekly Retention Points per roster member. Missed % = team (abandoned + voicemail) / (answered + those), applied to everyone who worked the week. Same missed definition as the Telegram daily block. Reduction = 0.04 x missed%^2, capped at 100 (total wipe at 50% missed).';

-- Added and replaced vehicles are sales, logged on the sales side of the same Activity Log page.
UPDATE public.retention_point_values
SET description = 'A change you made and finished on the customer''s policy, account, or billing: added or removed a driver, removed a vehicle, changed an address or coverage, took a payment, issued ID cards or proof of insurance, updated a lienholder or mortgagee, changed a beneficiary. Added and replaced vehicles are sales — log those on the sales side of this page. Getting a cancelled policy reinstated is a cancellation saved, which is worth more — log it there. Answering a question, reading a due date or bill amount, taking a message, or transferring the call is not a service task — picking up already earned the call point.',
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND activity_key = 'service_task';
