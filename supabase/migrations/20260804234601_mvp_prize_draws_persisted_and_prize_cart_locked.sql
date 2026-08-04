-- ═════════════════════════════════════════════════════════════════════════════
-- Two holes in the weekly prize cart.
-- ═════════════════════════════════════════════════════════════════════════════
-- 1. prize_cart had a single blanket rule allowing every signed-in person to
--    insert, change and delete any row. The claim was written straight from the
--    browser, so a teammate could name themselves the winner of any prize,
--    overwrite somebody else's win, or empty the cart.
--
-- 2. Spins were never recorded anywhere. The list of drawn prizes lived only in
--    the open page, so closing the window and reopening it handed back a fresh
--    set of spins. Anyone could keep re-rolling until a prize they liked came
--    up. Draws are earned from sales points for that week and there is exactly
--    one allotment per week, so they have to be spent and stay spent.
--
-- Draws are now written down as they happen, and claiming runs through a
-- function that checks the person, the week, the allotment and the prize.
-- ═════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.mvp_prize_draws (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id        uuid NOT NULL,
  team_member_id   uuid NOT NULL,
  week_ending_date date NOT NULL,
  prize_cart_id    uuid NOT NULL REFERENCES public.prize_cart(id) ON DELETE CASCADE,
  was_kept         boolean NOT NULL DEFAULT false,
  drawn_at         timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.mvp_prize_draws IS
  'One row per spin actually taken. Exists so that closing the prize window does not hand back spins already used. The weekly allotment lives on mvp_history.prize_draws and is earned from sales points.';

CREATE UNIQUE INDEX IF NOT EXISTS uq_mvp_prize_draws_one_per_prize
  ON public.mvp_prize_draws (agency_id, team_member_id, week_ending_date, prize_cart_id);
CREATE INDEX IF NOT EXISTS ix_mvp_prize_draws_week
  ON public.mvp_prize_draws (agency_id, week_ending_date, team_member_id);

ALTER TABLE public.mvp_prize_draws ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS mvp_prize_draws_select ON public.mvp_prize_draws;
CREATE POLICY mvp_prize_draws_select ON public.mvp_prize_draws
  FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
-- No write rules on purpose. Only the functions below put rows in here.

-- ── read the current position ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_mvp_draw_state(p_team_member_id uuid, p_week_ending_date date)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_agency   uuid := '126794dd-25ff-47d2-a436-724499733365'::uuid;
  v_allotted int;
  v_used     int;
  v_kept     int;
  v_won      int;
  v_draws    jsonb;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role'
     AND NOT public.is_agency_admin()
     AND p_team_member_id IS DISTINCT FROM public.current_team_member_id() THEN
    RAISE EXCEPTION 'not authorized to look at another person''s prize draws';
  END IF;

  SELECT h.prize_draws INTO v_allotted
  FROM public.mvp_history h
  WHERE h.agency_id = v_agency
    AND h.team_member_id = p_team_member_id
    AND h.week_ending_date = p_week_ending_date;
  v_allotted := coalesce(v_allotted, 0);

  SELECT count(*), count(*) FILTER (WHERE d.was_kept)
    INTO v_used, v_kept
  FROM public.mvp_prize_draws d
  WHERE d.agency_id = v_agency
    AND d.team_member_id = p_team_member_id
    AND d.week_ending_date = p_week_ending_date;

  -- Prizes claimed before this table existed still count as a claim.
  SELECT count(*) INTO v_won
  FROM public.prize_cart c
  WHERE c.agency_id = v_agency
    AND c.winner_team_member_id = p_team_member_id
    AND c.won_on = p_week_ending_date;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'prize_cart_id', d.prize_cart_id,
           'was_kept',      d.was_kept,
           'drawn_at',      d.drawn_at
         ) ORDER BY d.drawn_at), '[]'::jsonb)
    INTO v_draws
  FROM public.mvp_prize_draws d
  WHERE d.agency_id = v_agency
    AND d.team_member_id = p_team_member_id
    AND d.week_ending_date = p_week_ending_date;

  RETURN jsonb_build_object(
    'allotted',  v_allotted,
    'used',      v_used,
    'remaining', greatest(0, v_allotted - v_used),
    'claimed',   (v_kept > 0 OR v_won > 0),
    'draws',     v_draws
  );
END $$;

-- ── spend one draw ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_mvp_prize_draw(p_team_member_id uuid, p_week_ending_date date, p_prize_cart_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_agency   uuid := '126794dd-25ff-47d2-a436-724499733365'::uuid;
  v_allotted int;
  v_used     int;
  v_kept     int;
  v_won      int;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role'
     AND NOT public.is_agency_admin()
     AND p_team_member_id IS DISTINCT FROM public.current_team_member_id() THEN
    RAISE EXCEPTION 'not authorized to spin on another person''s behalf';
  END IF;

  -- Serialise per person per week so a double tap cannot spend two draws at once.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_team_member_id::text || p_week_ending_date::text, 0));

  SELECT h.prize_draws INTO v_allotted
  FROM public.mvp_history h
  WHERE h.agency_id = v_agency
    AND h.team_member_id = p_team_member_id
    AND h.week_ending_date = p_week_ending_date;

  IF coalesce(v_allotted, 0) <= 0 THEN
    RAISE EXCEPTION 'no prize draws were earned for the week ending %', p_week_ending_date;
  END IF;

  SELECT count(*), count(*) FILTER (WHERE d.was_kept)
    INTO v_used, v_kept
  FROM public.mvp_prize_draws d
  WHERE d.agency_id = v_agency
    AND d.team_member_id = p_team_member_id
    AND d.week_ending_date = p_week_ending_date;

  SELECT count(*) INTO v_won
  FROM public.prize_cart c
  WHERE c.agency_id = v_agency
    AND c.winner_team_member_id = p_team_member_id
    AND c.won_on = p_week_ending_date;

  IF v_kept > 0 OR v_won > 0 THEN
    RAISE EXCEPTION 'a prize has already been kept for the week ending %', p_week_ending_date;
  END IF;

  IF v_used >= v_allotted THEN
    RAISE EXCEPTION 'no draws left for the week ending % — % of % already used. More draws come from more sales points that week.',
      p_week_ending_date, v_used, v_allotted;
  END IF;

  PERFORM 1 FROM public.prize_cart c
  WHERE c.id = p_prize_cart_id
    AND c.agency_id = v_agency
    AND c.winner_team_member_id IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'that prize is not in the cart or has already been won';
  END IF;

  INSERT INTO public.mvp_prize_draws (agency_id, team_member_id, week_ending_date, prize_cart_id)
  VALUES (v_agency, p_team_member_id, p_week_ending_date, p_prize_cart_id);

  RETURN public.get_mvp_draw_state(p_team_member_id, p_week_ending_date);
END $$;

-- ── keep one of the drawn prizes ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.claim_mvp_prize(p_team_member_id uuid, p_week_ending_date date, p_prize_cart_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_agency  uuid := '126794dd-25ff-47d2-a436-724499733365'::uuid;
  v_draw_id uuid;
  v_desc    text;
  v_kept    int;
  v_won     int;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role'
     AND NOT public.is_agency_admin()
     AND p_team_member_id IS DISTINCT FROM public.current_team_member_id() THEN
    RAISE EXCEPTION 'not authorized to claim a prize for another person';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_team_member_id::text || p_week_ending_date::text, 0));

  SELECT count(*) FILTER (WHERE d.was_kept) INTO v_kept
  FROM public.mvp_prize_draws d
  WHERE d.agency_id = v_agency
    AND d.team_member_id = p_team_member_id
    AND d.week_ending_date = p_week_ending_date;

  SELECT count(*) INTO v_won
  FROM public.prize_cart c
  WHERE c.agency_id = v_agency
    AND c.winner_team_member_id = p_team_member_id
    AND c.won_on = p_week_ending_date;

  IF v_kept > 0 OR v_won > 0 THEN
    RAISE EXCEPTION 'a prize has already been kept for the week ending %', p_week_ending_date;
  END IF;

  SELECT d.id INTO v_draw_id
  FROM public.mvp_prize_draws d
  WHERE d.agency_id = v_agency
    AND d.team_member_id = p_team_member_id
    AND d.week_ending_date = p_week_ending_date
    AND d.prize_cart_id = p_prize_cart_id
    AND d.was_kept = false
  LIMIT 1;

  IF v_draw_id IS NULL THEN
    RAISE EXCEPTION 'that prize was not drawn for the week ending % — only a drawn prize can be kept', p_week_ending_date;
  END IF;

  UPDATE public.prize_cart
     SET winner_team_member_id = p_team_member_id,
         won_on                = p_week_ending_date,
         updated_at            = now()
   WHERE id = p_prize_cart_id
     AND agency_id = v_agency
     AND winner_team_member_id IS NULL
  RETURNING prize_description INTO v_desc;

  IF v_desc IS NULL THEN
    RAISE EXCEPTION 'that prize has already been won by somebody else';
  END IF;

  UPDATE public.mvp_prize_draws SET was_kept = true WHERE id = v_draw_id;

  RETURN jsonb_build_object('ok', true, 'prize_description', v_desc);
END $$;

REVOKE ALL ON ROUTINE public.get_mvp_draw_state(uuid, date)              FROM PUBLIC, anon;
REVOKE ALL ON ROUTINE public.record_mvp_prize_draw(uuid, date, uuid)     FROM PUBLIC, anon;
REVOKE ALL ON ROUTINE public.claim_mvp_prize(uuid, date, uuid)           FROM PUBLIC, anon;
GRANT EXECUTE ON ROUTINE public.get_mvp_draw_state(uuid, date)           TO authenticated, service_role;
GRANT EXECUTE ON ROUTINE public.record_mvp_prize_draw(uuid, date, uuid)  TO authenticated, service_role;
GRANT EXECUTE ON ROUTINE public.claim_mvp_prize(uuid, date, uuid)        TO authenticated, service_role;

-- ── the cart itself is now admin-only to write ───────────────────────────────
DROP POLICY IF EXISTS prize_cart_auth_write ON public.prize_cart;

CREATE POLICY prize_cart_admin_insert ON public.prize_cart
  FOR INSERT TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND public.is_agency_admin());

CREATE POLICY prize_cart_admin_update ON public.prize_cart
  FOR UPDATE TO authenticated
  USING      (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND public.is_agency_admin())
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND public.is_agency_admin());

CREATE POLICY prize_cart_admin_delete ON public.prize_cart
  FOR DELETE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND public.is_agency_admin());
