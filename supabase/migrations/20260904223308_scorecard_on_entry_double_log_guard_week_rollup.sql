-- 1. Double-log guard on activity. The same person logging the same item
--    for the same customer on the same day, in a SEPARATE entry, is a
--    refresh or a second tap. Rows created inside the current entry are
--    not counted (created_at = now() for those), so two Policy Changes in
--    one entry still go through. Voided rows never count, so Undo then
--    re-log works.
CREATE OR REPLACE FUNCTION public.rp_log_activity(p_items jsonb, p_customer_first text, p_customer_last_initial text, p_occurred_on date DEFAULT NULL::date, p_ecrm_url text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_team_member_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; item jsonb; v RECORD;
  v_today date := public.rp_today_central();
  v_on date; v_label text; v_key text; v_reason text; v_line text;
  v_credit_on date; v_credit_week date; v_id uuid;
  v_created jsonb := '[]'::jsonb; v_total numeric := 0; v_note text; v_url text;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(p_team_member_id);
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'check at least one thing you did';
  END IF;
  v_on := COALESCE(p_occurred_on, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'date cannot be in the future'; END IF;
  IF v_on < v_today - 7 THEN RAISE EXCEPTION 'log within 7 days of when it happened'; END IF;
  v_label := public.rp_customer_label(p_customer_first, p_customer_last_initial);
  v_note := NULLIF(btrim(COALESCE(p_note,'')), '');
  v_url  := NULLIF(btrim(COALESCE(p_ecrm_url,'')), '');
  IF v_url IS NOT NULL AND v_url !~* '^https?://' THEN RAISE EXCEPTION 'ECRM link must start with http'; END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_key := item->>'activity_key';
    SELECT * INTO v FROM public.retention_point_values
    WHERE agency_id = a.agency_id AND activity_key = v_key AND is_active AND category = 'logged';
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown or not-loggable item: %', v_key; END IF;
    IF v.requires_note AND v_note IS NULL AND NULLIF(btrim(COALESCE(item->>'save_reason','')),'') IS NULL THEN
      RAISE EXCEPTION '% needs a note on what you covered / the reason', v.label;
    END IF;
    IF EXISTS (SELECT 1 FROM public.retention_activity_log l
               WHERE l.agency_id = a.agency_id AND l.team_member_id = a.team_member_id
                 AND l.activity_key = v_key AND l.customer_label = v_label AND l.occurred_on = v_on
                 AND l.status = 'credited' AND l.created_at < now()) THEN
      RAISE EXCEPTION '% for % is already logged for %. Use Undo or remove the first one if that was a mistake.',
        v.label, v_label, CASE WHEN v_on = v_today THEN 'today' ELSE to_char(v_on, 'Mon FMDD') END;
    END IF;

    v_credit_on := NULL; v_credit_week := public.rp_week_end(v_on); v_reason := NULL; v_line := NULL;
    IF v_key = 'cancelation_saved' THEN
      IF v_on <> v_today THEN RAISE EXCEPTION 'a save is logged the same business day the request or notice comes in'; END IF;
      v_reason := NULLIF(btrim(COALESCE(item->>'save_reason','')), '');
      v_line   := NULLIF(lower(btrim(COALESCE(item->>'save_line',''))), '');
      IF v_reason IS NULL THEN RAISE EXCEPTION 'a save needs the reason the customer gave'; END IF;
      IF v_line IS NULL OR v_line NOT IN ('auto','fire','business','life','health','ips','bank') THEN
        RAISE EXCEPTION 'a save needs the policy line that was at risk';
      END IF;
      IF EXISTS (SELECT 1 FROM public.retention_activity_log l
                 WHERE l.agency_id = a.agency_id AND l.activity_key = 'cancelation_saved' AND l.status = 'credited'
                   AND l.customer_label = v_label AND l.save_line = v_line AND l.occurred_on > v_on - 90) THEN
        RAISE EXCEPTION 'one save per policy per ninety days — % already has a % save on file', v_label, v_line;
      END IF;
      v_credit_on := v_on + 30;
      v_credit_week := public.rp_week_end(v_credit_on);
    END IF;

    INSERT INTO public.retention_activity_log
      (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date, credit_available_on,
       customer_first_name, customer_last_initial, customer_label, ecrm_url, note, save_reason, save_line, points, source, created_by)
    VALUES
      (a.agency_id, a.team_member_id, v_key, v_on, public.rp_week_end(v_on), v_credit_week, v_credit_on,
       btrim(p_customer_first), upper(btrim(p_customer_last_initial)), v_label, v_url, v_note, v_reason, v_line, v.points, 'manual', a.actor_id)
    RETURNING id INTO v_id;
    v_total := v_total + v.points;
    v_created := v_created || jsonb_build_object('id', v_id, 'activity_key', v_key, 'label', v.label, 'points', v.points,
                                                 'credit_available_on', v_credit_on, 'credited_week_end_date', v_credit_week);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'customer', v_label, 'team_member_id', a.team_member_id,
                            'items', v_created, 'points_total', v_total);
END $function$;

-- 2. Scorecard rides on the entry. The FIT scorecard (10 dimensions, 1-3 or
--    N/A) lands in fit_scorecards the same way the Scorecards page writes
--    it; tenure tier and entry type are stamped from the same functions
--    and trigger. Whoever the entry is logged for owns the scorecard.
CREATE OR REPLACE FUNCTION public.rp_log_scorecard(p_payload jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload,'{}'::jsonb); v_today date := public.rp_today_central();
  v_on date; v_tier text; v_user uuid; v_id uuid; v_avg numeric; v_n integer := 0; k text;
  v_keys text[] := ARRAY['demeanor_score','frogs_score','intro_score','eligibility_score','setup_gnc_score',
                         'uncover_gap_score','bridge_gap_score','customize_close_score','set_followup_score','review_referral_score'];
  v_val integer;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  v_on := COALESCE(NULLIF(p->>'scorecard_date','')::date, v_today);
  IF v_on > v_today THEN RAISE EXCEPTION 'scorecard date cannot be in the future'; END IF;
  FOREACH k IN ARRAY v_keys LOOP
    v_val := NULLIF(p->>k,'')::integer;
    IF v_val IS NOT NULL THEN
      IF v_val NOT BETWEEN 1 AND 3 THEN RAISE EXCEPTION 'scorecard scores are 1, 2, 3, or left blank'; END IF;
      v_n := v_n + 1;
    END IF;
  END LOOP;
  IF v_n = 0 THEN RAISE EXCEPTION 'score at least one part of the conversation'; END IF;
  v_tier := public.fit_scorecard_tenure_tier(a.team_member_id, v_on);
  IF v_tier IS NULL THEN RAISE EXCEPTION 'no start date on file for this team member, so the scorecard tier cannot be set'; END IF;
  SELECT u.id INTO v_user FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1;
  INSERT INTO public.fit_scorecards (agency_id, team_member_id, created_by_user_id, scorecard_date, entry_type, tenure_tier_at_entry,
    customer_first_name, opportunity_ref, recording_turned_in, recording_url, notes,
    demeanor_score, frogs_score, intro_score, eligibility_score, setup_gnc_score,
    uncover_gap_score, bridge_gap_score, customize_close_score, set_followup_score, review_referral_score)
  VALUES (a.agency_id, a.team_member_id, v_user, v_on, public.fit_scorecard_entry_type_for_tenure(v_tier), v_tier,
    NULLIF(btrim(COALESCE(p->>'customer_first','')),''), NULLIF(btrim(COALESCE(p->>'ecrm_opportunity_url','')),''),
    COALESCE((p->>'recording_turned_in')::boolean, false), NULLIF(btrim(COALESCE(p->>'recording_url','')),''),
    NULLIF(btrim(COALESCE(p->>'note','')),''),
    NULLIF(p->>'demeanor_score','')::integer, NULLIF(p->>'frogs_score','')::integer, NULLIF(p->>'intro_score','')::integer,
    NULLIF(p->>'eligibility_score','')::integer, NULLIF(p->>'setup_gnc_score','')::integer, NULLIF(p->>'uncover_gap_score','')::integer,
    NULLIF(p->>'bridge_gap_score','')::integer, NULLIF(p->>'customize_close_score','')::integer, NULLIF(p->>'set_followup_score','')::integer,
    NULLIF(p->>'review_referral_score','')::integer)
  RETURNING id, average_score INTO v_id, v_avg;
  RETURN jsonb_build_object('ok', true, 'scorecard_id', v_id, 'average_score', v_avg, 'scored', v_n, 'tier', v_tier);
END $function$;
REVOKE ALL ON FUNCTION public.rp_log_scorecard(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_log_scorecard(jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.rp_log_entry(p_payload jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  p        jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_first  text  := p->>'customer_first';
  v_init   text  := p->>'customer_last_initial';
  v_on     date  := NULLIF(p->>'occurred_on', '')::date;
  v_url    text  := NULLIF(btrim(COALESCE(p->>'ecrm_url', '')), '');
  v_note   text  := NULLIF(btrim(COALESCE(p->>'note', '')), '');
  v_tm     uuid  := NULLIF(p->>'team_member_id', '')::uuid;
  v_rel    text  := NULLIF(lower(btrim(COALESCE(p->>'relationship_type', ''))), '');
  v_src    text  := NULLIF(btrim(COALESCE(p->>'marketing_source', '')), '');
  v_gnc    text  := NULLIF(p->>'gnc_used', '');
  v_srcby  text  := NULLIF(p->>'sourced_by_team_member_id', '');
  v_act    jsonb := p->'activity';
  v_quote  jsonb := p->'quote';
  v_sale   jsonb := p->'sale';
  v_cxl    jsonb := p->'cancelation';
  v_card   jsonb := p->'scorecard';
  v_cxl_items jsonb := '[]'::jsonb;
  v_items  jsonb := '[]'::jsonb;
  v_shared jsonb;
  it       jsonb;
  v_cnt    integer;
  i        integer;
  r_act    jsonb; r_quote jsonb; r_sale jsonb; r_cxl jsonb := '[]'::jsonb; r_one jsonb; r_card jsonb;
BEGIN
  IF v_act IS NULL OR jsonb_typeof(v_act) <> 'object'
     OR jsonb_typeof(v_act->'items') <> 'array' OR jsonb_array_length(v_act->'items') = 0 THEN
    v_act := NULL;
  END IF;
  IF v_quote IS NULL OR jsonb_typeof(v_quote) <> 'object'
     OR jsonb_typeof(v_quote->'items') <> 'array' OR jsonb_array_length(v_quote->'items') = 0 THEN
    v_quote := NULL;
  END IF;
  IF v_sale IS NULL OR jsonb_typeof(v_sale) <> 'object'
     OR jsonb_typeof(v_sale->'products') <> 'array' OR jsonb_array_length(v_sale->'products') = 0 THEN
    v_sale := NULL;
  END IF;
  IF v_cxl IS NOT NULL AND jsonb_typeof(v_cxl) = 'object' AND jsonb_typeof(v_cxl->'items') = 'array' THEN
    v_cxl_items := v_cxl->'items';
  END IF;
  IF jsonb_array_length(v_cxl_items) = 0 THEN v_cxl := NULL; END IF;
  IF jsonb_array_length(v_cxl_items) > 40 THEN RAISE EXCEPTION 'more than 40 canceled policies in one entry. Double-check it.'; END IF;
  IF v_card IS NULL OR jsonb_typeof(v_card) <> 'object' THEN v_card := NULL; END IF;

  IF v_act IS NULL AND v_quote IS NULL AND v_sale IS NULL AND v_cxl IS NULL AND v_card IS NULL THEN
    RAISE EXCEPTION 'add at least one thing to log: an activity, a policy, or a scorecard';
  END IF;

  IF v_sale IS NOT NULL AND v_cxl IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_sale->'products') s
               JOIN jsonb_array_elements(v_cxl_items) c
                 ON lower(btrim(COALESCE(s->>'line_of_business',''))) = lower(btrim(COALESCE(c->>'line_of_business','')))) THEN
      RAISE EXCEPTION 'a sale and a cancelation on the same policy line cannot go in one entry. Log them separately.';
    END IF;
  END IF;

  v_shared := jsonb_build_object(
    'customer_first', v_first, 'customer_last_initial', v_init,
    'ecrm_opportunity_url', v_url, 'note', v_note, 'team_member_id', v_tm,
    'relationship_type', v_rel, 'household_status', v_rel,
    'marketing_source', v_src, 'gnc_used', v_gnc, 'sourced_by_team_member_id', v_srcby);

  IF v_act IS NOT NULL THEN
    FOR it IN SELECT * FROM jsonb_array_elements(v_act->'items') LOOP
      v_cnt := GREATEST(1, COALESCE(NULLIF(it->>'count', '')::integer, 1));
      IF v_cnt > 50 THEN RAISE EXCEPTION 'more than 50 of one item in a single entry. Double-check the count.'; END IF;
      FOR i IN 1..v_cnt LOOP v_items := v_items || (it - 'count'); END LOOP;
    END LOOP;
    r_act := public.rp_log_activity(v_items, v_first, v_init, v_on, v_url, v_note, v_tm);
  END IF;
  IF v_quote IS NOT NULL THEN
    r_quote := public.rp_log_quote(v_shared || v_quote || jsonb_build_object('quote_date', v_on));
  END IF;
  IF v_sale IS NOT NULL THEN
    r_sale := public.rp_log_sale(v_shared || v_sale || jsonb_build_object('sale_date', v_on));
  END IF;
  IF v_cxl IS NOT NULL THEN
    FOR it IN SELECT * FROM jsonb_array_elements(v_cxl_items) LOOP
      r_one := public.rp_log_cancelation(jsonb_build_object(
        'customer_first', v_first, 'customer_last_initial', v_init, 'canceled_on', v_on,
        'policy_line', it->>'line_of_business', 'product_type', it->>'product_type',
        'premium', it->>'premium', 'vehicle_count', it->>'vehicle_count',
        'reason', v_cxl->>'reason', 'note', v_note, 'team_member_id', v_tm));
      r_cxl := r_cxl || r_one;
    END LOOP;
  END IF;
  IF v_card IS NOT NULL THEN
    r_card := public.rp_log_scorecard(v_shared || v_card || jsonb_build_object('scorecard_date', v_on));
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'customer', public.rp_customer_label(v_first, v_init),
    'activity', r_act, 'quote', r_quote, 'sale', r_sale,
    'cancelation', CASE WHEN v_cxl IS NULL THEN NULL ELSE r_cxl END,
    'scorecard', r_card);
END $function$;

-- Undo removes the scorecard row too (it has no void state; it is the
-- logger's own row from seconds ago).
CREATE OR REPLACE FUNCTION public.rp_undo_entry(p_result jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r jsonb := COALESCE(p_result, '{}'::jsonb); it jsonb; v_n integer := 0; v_cxl uuid; v_why text := 'undone right after logging'; a RECORD;
BEGIN
  FOR it IN SELECT * FROM jsonb_array_elements(COALESCE(r->'activity'->'items', '[]'::jsonb)) LOOP
    PERFORM public.rp_void_activity((it->>'id')::uuid, v_why); v_n := v_n + 1;
  END LOOP;
  IF NULLIF(r->'quote'->>'quote_id', '') IS NOT NULL THEN
    PERFORM public.rp_void_quote((r->'quote'->>'quote_id')::uuid, v_why); v_n := v_n + 1;
  END IF;
  IF NULLIF(r->'sale'->>'sale_id', '') IS NOT NULL THEN
    PERFORM public.rp_void_sale((r->'sale'->>'sale_id')::uuid, v_why); v_n := v_n + 1;
  END IF;
  FOR it IN SELECT * FROM jsonb_array_elements(CASE WHEN jsonb_typeof(r->'cancelation') = 'array' THEN r->'cancelation' ELSE '[]'::jsonb END) LOOP
    v_cxl := (it->>'cancelation_id')::uuid;
    PERFORM public.rp_void_cancelation(v_cxl, v_why);
    UPDATE public.retention_activity_log l
       SET status = 'credited', voided_at = NULL, voided_by = NULL, void_reason = NULL, updated_at = now()
      FROM public.cancelation_log c
     WHERE c.id = v_cxl AND l.agency_id = c.agency_id
       AND l.activity_key = 'cancelation_saved' AND l.status = 'void'
       AND l.customer_label = c.customer_label AND l.save_line = c.policy_line
       AND l.voided_at >= c.created_at - interval '1 second'
       AND l.void_reason LIKE 'policy canceled %';
    v_n := v_n + 1;
  END LOOP;
  IF NULLIF(r->'scorecard'->>'scorecard_id', '') IS NOT NULL THEN
    SELECT * INTO a FROM public.rp_resolve_actor(NULL);
    DELETE FROM public.fit_scorecards f WHERE f.id = (r->'scorecard'->>'scorecard_id')::uuid
      AND f.agency_id = a.agency_id AND f.created_at > now() - interval '1 hour';
    v_n := v_n + 1;
  END IF;
  RETURN jsonb_build_object('ok', true, 'undone', v_n);
END $function$;

-- 3. Week rollup for My week: scorecard average and count, asks against
--    outcomes. One call, one row per team member for the week.
CREATE OR REPLACE FUNCTION public.rp_week_rollup(p_week_end date, p_team_member_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(team_member_id uuid, scorecards integer, scorecard_avg numeric,
               pivots integer, review_asks integer, referral_asks integer,
               policy_reviews integer, google_reviews integer, referrals_sold integer)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
  members AS (
    SELECT t.id FROM public.team t JOIN me ON me.agency_id = t.agency_id
    WHERE t.archived_at IS NULL AND (p_team_member_id IS NULL OR t.id = p_team_member_id)
  ),
  cards AS (
    SELECT f.team_member_id, count(*)::integer AS n, round(avg(f.average_score), 2) AS avg
    FROM public.fit_scorecards f JOIN me ON me.agency_id = f.agency_id
    WHERE f.scorecard_date BETWEEN p_week_end - 6 AND p_week_end
    GROUP BY f.team_member_id
  ),
  acts AS (
    SELECT l.team_member_id,
      count(*) FILTER (WHERE l.activity_key = 'pivot')::integer AS pivots,
      count(*) FILTER (WHERE l.activity_key = 'review_ask')::integer AS review_asks,
      count(*) FILTER (WHERE l.activity_key = 'referral_ask')::integer AS referral_asks,
      count(*) FILTER (WHERE l.activity_key = 'policy_review')::integer AS policy_reviews,
      count(*) FILTER (WHERE l.activity_key = 'google_review')::integer AS google_reviews,
      count(*) FILTER (WHERE l.activity_key = 'referral_sold')::integer AS referrals_sold
    FROM public.retention_activity_log l JOIN me ON me.agency_id = l.agency_id
    WHERE l.week_end_date = p_week_end AND l.status = 'credited'
    GROUP BY l.team_member_id
  )
  SELECT m.id, COALESCE(c.n, 0), c.avg,
         COALESCE(a.pivots, 0), COALESCE(a.review_asks, 0), COALESCE(a.referral_asks, 0),
         COALESCE(a.policy_reviews, 0), COALESCE(a.google_reviews, 0), COALESCE(a.referrals_sold, 0)
  FROM members m LEFT JOIN cards c ON c.team_member_id = m.id LEFT JOIN acts a ON a.team_member_id = m.id
  WHERE auth.uid() IS NOT NULL;
$function$;
REVOKE ALL ON FUNCTION public.rp_week_rollup(date, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_week_rollup(date, uuid) TO authenticated;
