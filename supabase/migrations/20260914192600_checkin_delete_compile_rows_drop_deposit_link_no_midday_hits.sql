-- Peter 2026-09-14, three corrections.

-- 1. The two dead compile recipes go for good. Their run-log rows were the only
--    thing holding them, and the log of a step that no longer exists is not
--    worth keeping. Rows first, then the recipes.
DELETE FROM public.automation_run_log
WHERE recipe_id IN (
  SELECT id FROM public.automation_recipes
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND internal_handler = 'team_checkin_compile_results');

DELETE FROM public.automation_recipes
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND internal_handler = 'team_checkin_compile_results';

-- 2. The deposit records link comes off the EOD message. The wrap-up link
--    replaced it.
-- 3. The midday message stops marking commits hit or missed. Hit marks are an
--    end-of-day thing.
CREATE OR REPLACE FUNCTION public.team_checkin_build_results_message(
  p_agency_id uuid,
  p_checkin_type text,
  p_date date
) RETURNS TABLE(
  message_text text,
  parse_mode text,
  expected_count integer,
  fresh_count integer,
  team_quotes numeric,
  team_sales numeric
)
LANGUAGE plpgsql
AS $function$
DECLARE
  v_is_eod boolean; v_lead text; v_label text;
  v_block record; v_text text; v_commits text; v_votes int;
  v_wrapup_url text := 'https://newtworks.vercel.app/?tab=checklist';
BEGIN
  IF p_checkin_type NOT IN ('midday', 'eod') THEN
    RAISE EXCEPTION 'team_checkin_build_results_message: unsupported checkin_type %',
      p_checkin_type;
  END IF;

  v_is_eod := (p_checkin_type = 'eod');
  v_lead   := CASE WHEN v_is_eod THEN '🌙' ELSE '☀️' END;
  v_label  := CASE WHEN v_is_eod THEN 'EOD' ELSE 'Midday' END;

  -- Kept from the old compile step so the in-progress CPR row still gets made.
  PERFORM public.weekly_cpr_upsert_in_progress(p_agency_id, p_date);

  SELECT * INTO v_block FROM public.render_team_status_block(
    p_agency_id, p_date, p_checkin_type,
    v_lead || ' ' || v_label || ' ' || to_char(p_date, 'Mon DD'));
  v_text := rtrim(v_block.block_text, E'\n');

  IF v_block.encouragement_text IS NOT NULL THEN
    v_text := v_text || E'\n' || v_block.encouragement_text;
  END IF;

  -- Hit and miss marks only at end of day (Peter 2026-09-14). At midday the
  -- commits are still in flight.
  v_commits := public.render_daily_commits_block(p_agency_id, p_date, v_is_eod, v_is_eod);
  IF v_commits IS NOT NULL THEN
    v_text := v_text || E'\n\n' || v_commits;
  END IF;

  -- EOD-only line. Runs every day, no Friday variation (Peter 2026-09-14).
  IF v_is_eod THEN
    v_text := v_text || E'\n\n📝 <a href="' || v_wrapup_url
                     || E'">Don''t forget wrap-up</a>';
  END IF;

  SELECT COUNT(*)::int INTO v_votes
  FROM public.time_off_requests
  WHERE agency_id = p_agency_id AND status = 'voting' AND vote_closes_at > now();
  IF v_votes = 1 THEN
    v_text := v_text || E'\n\n🗳️ Vote Required';
  ELSIF v_votes > 1 THEN
    v_text := v_text || E'\n\n🗳️ Vote Required (' || v_votes::text || ')';
  END IF;

  -- The nag at +20 reads team_checkin_acks, so the acknowledgment line has to be
  -- here. One copy of the wording lives in team_checkin_reminder_ack_line().
  v_text := v_text || E'\n\n' || public.team_checkin_reminder_ack_line();

  RETURN QUERY SELECT
    v_text,
    CASE WHEN v_is_eod THEN 'HTML' ELSE NULL END::text,
    v_block.expected_count,
    v_block.fresh_count,
    v_block.team_total_quotes,
    v_block.team_total_sales;
END;
$function$;