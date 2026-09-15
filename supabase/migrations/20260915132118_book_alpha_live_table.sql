-- The alphabet split is not a history of point-in-time snapshots. It is one
-- current answer: who has which letters, and how many households sit under each.
-- One row per letter. Edit it in place.

CREATE TABLE IF NOT EXISTS public.book_alpha (
  agency_id        uuid NOT NULL,
  letter           text NOT NULL,
  team_member_id   uuid REFERENCES public.team(id),
  household_count  integer NOT NULL DEFAULT 0 CHECK (household_count >= 0),
  sort_order       integer NOT NULL DEFAULT 0,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agency_id, letter)
);

ALTER TABLE public.book_alpha ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS book_alpha_read ON public.book_alpha;
CREATE POLICY book_alpha_read ON public.book_alpha
  FOR SELECT TO authenticated
  USING (agency_id = (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1));

-- Seed the letters and their counts from the last snapshot that was taken, and
-- take ownership from the team records, which are the live answer.
INSERT INTO public.book_alpha (agency_id, letter, team_member_id, household_count, sort_order)
SELECT s.agency_id,
       s.letter_bucket,
       (SELECT t.id FROM public.team t
         WHERE t.agency_id = s.agency_id AND t.is_active AND t.archived_at IS NULL
           AND t.account_alpha IS NOT NULL
           AND left(s.letter_bucket, 1) BETWEEN split_part(t.account_alpha, '-', 1)
                                            AND COALESCE(NULLIF(split_part(t.account_alpha, '-', 2), ''), split_part(t.account_alpha, '-', 1))
         LIMIT 1),
       s.account_count,
       ascii(left(s.letter_bucket, 1))
FROM public.book_alpha_split s
WHERE s.snapshot_date = (SELECT MAX(snapshot_date) FROM public.book_alpha_split x WHERE x.agency_id = s.agency_id)
ON CONFLICT (agency_id, letter) DO NOTHING;

-- Read: one entry per person who has letters, their letters, and their total.
CREATE OR REPLACE FUNCTION public.rp_book_alpha()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; v_people jsonb; v_free jsonb;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);

  SELECT COALESCE(jsonb_agg(p ORDER BY p.name), '[]'::jsonb) INTO v_people
  FROM (
    SELECT t.id AS team_member_id,
           COALESCE(NULLIF(btrim(t.nickname), ''), t.first_name) AS name,
           SUM(b.household_count)::integer AS total_households,
           jsonb_agg(jsonb_build_object('letter', b.letter, 'household_count', b.household_count)
                     ORDER BY b.sort_order, b.letter) AS letters
      FROM public.book_alpha b
      JOIN public.team t ON t.id = b.team_member_id
     WHERE b.agency_id = a.agency_id
     GROUP BY t.id, COALESCE(NULLIF(btrim(t.nickname), ''), t.first_name)
  ) p;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('letter', b.letter, 'household_count', b.household_count)
                            ORDER BY b.sort_order, b.letter), '[]'::jsonb) INTO v_free
    FROM public.book_alpha b
   WHERE b.agency_id = a.agency_id AND b.team_member_id IS NULL;

  RETURN jsonb_build_object('ok', true, 'people', v_people, 'unassigned', v_free,
                            'can_edit', COALESCE(public.current_app_user_role() = 'owner', false));
END $function$;

-- Write: takes the whole grid back. Owner only.
CREATE OR REPLACE FUNCTION public.rp_book_alpha_save(p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; row jsonb; v_letter text; v_tm uuid; v_n integer;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT COALESCE(public.current_app_user_role() = 'owner', false) THEN
    RAISE EXCEPTION 'only the owner can change the alphabet split' USING ERRCODE='42501';
  END IF;
  IF jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'nothing to save'; END IF;

  FOR row IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_letter := upper(btrim(COALESCE(row->>'letter','')));
    IF v_letter = '' THEN RAISE EXCEPTION 'every row needs a letter'; END IF;
    v_tm := NULLIF(row->>'team_member_id','')::uuid;
    IF v_tm IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.team t WHERE t.id = v_tm AND t.agency_id = a.agency_id) THEN
      RAISE EXCEPTION 'that person is not on this team';
    END IF;
    v_n := GREATEST(0, COALESCE(NULLIF(row->>'household_count','')::integer, 0));

    INSERT INTO public.book_alpha (agency_id, letter, team_member_id, household_count, sort_order, updated_at)
    VALUES (a.agency_id, v_letter, v_tm, v_n, ascii(left(v_letter, 1)), now())
    ON CONFLICT (agency_id, letter) DO UPDATE
      SET team_member_id = EXCLUDED.team_member_id,
          household_count = EXCLUDED.household_count,
          updated_at = now();
  END LOOP;

  -- team.account_alpha is the short version other screens read. Keep it true.
  UPDATE public.team t
     SET account_alpha = g.range_text, updated_at = now()
    FROM (
      SELECT b.team_member_id,
             CASE WHEN MIN(left(b.letter,1)) = MAX(left(b.letter,1)) THEN MIN(left(b.letter,1))
                  ELSE MIN(left(b.letter,1)) || '-' || MAX(right(b.letter,1)) END AS range_text
        FROM public.book_alpha b
       WHERE b.agency_id = a.agency_id AND b.team_member_id IS NOT NULL
       GROUP BY b.team_member_id
    ) g
   WHERE t.id = g.team_member_id AND t.account_alpha IS DISTINCT FROM g.range_text;

  UPDATE public.team t SET account_alpha = NULL, updated_at = now()
   WHERE t.agency_id = a.agency_id AND t.account_alpha IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.book_alpha b WHERE b.agency_id = a.agency_id AND b.team_member_id = t.id);

  RETURN public.rp_book_alpha();
END $function$;

-- The edit form needs to know whether an auto line was added to an existing
-- policy. Sourced-by comes out at the same time.
CREATE OR REPLACE FUNCTION public.rp_entry_for_edit(p_kind text, p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; v_kind text := lower(btrim(COALESCE(p_kind, ''))); v_out jsonb;
  v_week date := public.rp_week_end(public.rp_today_central());
  v_today timestamptz := public.rp_today_central()::timestamptz;
  s RECORD; q RECORD; c RECORD; l RECORD; f RECORD;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);

  IF v_kind = 'sale' THEN
    SELECT * INTO s FROM public.sales_log WHERE id = p_id AND agency_id = a.agency_id AND status = 'active';
    IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
    v_out := jsonb_build_object(
      'kind', 'sale', 'id', s.id, 'team_member_id', s.team_member_id,
      'customer_first', s.customer_first_name, 'customer_last_initial', s.customer_last_initial,
      'phone_last4', s.phone_last4, 'date', s.submitted_date,
      'relationship', s.household_status, 'marketing_source', s.marketing_source,
      'ecrm_url', s.ecrm_opportunity_url, 'note', s.note,
      'entry_source', COALESCE(s.entry_source, 'manual'),
      'week_end_date', s.week_end_date, 'created_at', s.created_at,
      'products', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('id', p.id, 'line_of_business', p.line_of_business,
                 'product_type', p.product_type, 'premium', p.premium, 'policy_count', p.policy_count,
                 'vehicle_count', p.vehicle_count, 'is_new_line', p.is_new_line,
                 'added_to_existing', p.is_added_to_existing,
                 'issued_date', p.issued_date, 'issued_premium', p.issued_premium,
                 'autopay', p.autopay_enrolled) ORDER BY p.created_at, p.id)
          FROM public.sales_log_products p WHERE p.sales_log_id = s.id), '[]'::jsonb));

  ELSIF v_kind = 'quote' THEN
    SELECT * INTO q FROM public.quote_log WHERE id = p_id AND agency_id = a.agency_id AND status = 'active';
    IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
    v_out := jsonb_build_object(
      'kind', 'quote', 'id', q.id, 'team_member_id', q.team_member_id,
      'customer_first', q.customer_first_name, 'customer_last_initial', q.customer_last_initial,
      'phone_last4', q.phone_last4, 'date', q.quote_date,
      'relationship', q.relationship_type, 'marketing_source', q.marketing_source,
      'ecrm_url', q.ecrm_opportunity_url, 'note', q.note,
      'entry_source', 'manual', 'week_end_date', q.week_end_date, 'created_at', q.created_at,
      'products', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('id', p.id, 'line_of_business', p.line_of_business,
                 'product_type', p.product_type) ORDER BY p.created_at, p.id)
          FROM public.quote_log_products p WHERE p.quote_log_id = q.id), '[]'::jsonb));

  ELSIF v_kind = 'cancelation' THEN
    SELECT * INTO c FROM public.cancelation_log WHERE id = p_id AND agency_id = a.agency_id AND status = 'active';
    IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
    v_out := jsonb_build_object(
      'kind', 'cancelation', 'id', c.id, 'team_member_id', c.team_member_id,
      'customer_first', c.customer_first_name, 'customer_last_initial', c.customer_last_initial,
      'phone_last4', c.phone_last4, 'date', c.canceled_on,
      'policy_line', c.policy_line, 'product_type', c.product_type,
      'premium', c.premium, 'vehicle_count', c.vehicle_count, 'reason', c.reason, 'note', c.note,
      'entry_source', 'manual', 'week_end_date', c.week_end_date, 'created_at', c.created_at,
      'products', '[]'::jsonb);

  ELSIF v_kind = 'activity' THEN
    SELECT * INTO l FROM public.retention_activity_log WHERE id = p_id AND agency_id = a.agency_id AND status <> 'void';
    IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
    v_out := jsonb_build_object(
      'kind', 'activity', 'id', l.id, 'team_member_id', l.team_member_id,
      'customer_first', l.customer_first_name, 'customer_last_initial', l.customer_last_initial,
      'phone_last4', l.phone_last4, 'date', l.occurred_on,
      'activity_key', l.activity_key, 'note', l.note, 'ecrm_url', l.ecrm_url,
      'save_line', l.save_line, 'save_reason', l.save_reason,
      'policy_line', l.policy_line, 'product_type', l.product_type, 'premium', l.premium,
      'points', l.points,
      'entry_source', 'manual', 'week_end_date', l.week_end_date, 'created_at', l.created_at,
      'products', '[]'::jsonb);

  ELSIF v_kind = 'scorecard' THEN
    SELECT * INTO f FROM public.fit_scorecards WHERE id = p_id AND agency_id = a.agency_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
    v_out := jsonb_build_object(
      'kind', 'scorecard', 'id', f.id, 'team_member_id', f.team_member_id,
      'customer_first', f.customer_first_name, 'customer_last_initial', NULL,
      'phone_last4', f.phone_last4, 'date', f.scorecard_date,
      'recording_turned_in', f.recording_turned_in, 'recording_url', f.recording_url,
      'note', f.notes, 'entry_source', 'manual',
      'week_end_date', public.rp_week_end(f.scorecard_date), 'created_at', f.created_at,
      'scores', jsonb_build_object(
        'demeanor_score', f.demeanor_score, 'frogs_score', f.frogs_score, 'intro_score', f.intro_score,
        'eligibility_score', f.eligibility_score, 'setup_gnc_score', f.setup_gnc_score,
        'uncover_gap_score', f.uncover_gap_score, 'bridge_gap_score', f.bridge_gap_score,
        'customize_close_score', f.customize_close_score, 'set_followup_score', f.set_followup_score,
        'review_referral_score', f.review_referral_score),
      'products', '[]'::jsonb);
  ELSE
    RAISE EXCEPTION 'unknown record type: %', p_kind;
  END IF;

  RETURN v_out || jsonb_build_object('can_change',
    (a.is_admin OR ((v_out->>'team_member_id')::uuid = a.actor_id
                    AND ((v_out->>'week_end_date')::date >= v_week
                         OR (v_out->>'created_at')::timestamptz >= v_today))));
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_book_alpha() TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_book_alpha_save(jsonb) TO authenticated;
