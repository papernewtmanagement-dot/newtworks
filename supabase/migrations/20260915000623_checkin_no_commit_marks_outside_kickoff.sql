-- Peter 2026-09-14: the done / missed mark belongs only on the morning kickoff
-- message. Midday and end of day still list the commits, without marks.
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

  -- No done / missed marks here. Those live on the kickoff message only.
  v_commits := public.render_daily_commits_block(p_agency_id, p_date, false, v_is_eod);
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
