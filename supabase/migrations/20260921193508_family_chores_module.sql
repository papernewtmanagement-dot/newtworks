-- Family module: kids, chores, checklists, chore log, money ledger.
-- Money rules (one place each):
--   family_chore_fine()  -> the fine for one chore
--   family_log_amount()  -> the dollar effect of one status on one chore
--   family_set_status()  -> the only writer of chore outcomes
--   family_sweep_missed()-> marks past, unlogged chores as missed
--   family_balances()    -> spend / tithe / invest per kid
-- Response cost design (a fine for a skipped behavior) follows the token
-- economy literature: fines kept small next to what can be earned, and
-- predictable, so a child is not driven so far negative that the system stops
-- working (Kazdin, The Token Economy, 1977; Walker, 1983). A false claim costs
-- more than an honest skip so owning up is always the cheaper choice
-- (Talwar, Arruda & Yachison, 2015, J Exp Child Psychol 130:209-217).

CREATE TABLE IF NOT EXISTS public.family_settings (
  agency_id uuid PRIMARY KEY,
  min_fine numeric(8,2) NOT NULL DEFAULT 0.25 CHECK (min_fine >= 0),
  false_claim_multiplier numeric(6,2) NOT NULL DEFAULT 2 CHECK (false_claim_multiplier >= 1),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.family_kids (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  name text NOT NULL,
  sort_order int NOT NULL DEFAULT 0,
  tithe_pct numeric(5,2) NOT NULL DEFAULT 10 CHECK (tithe_pct BETWEEN 0 AND 100),
  invest_pct numeric(5,2) NOT NULL DEFAULT 10 CHECK (invest_pct BETWEEN 0 AND 100),
  tracking_start date NOT NULL DEFAULT ((now() AT TIME ZONE 'America/Chicago')::date),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.family_checklists (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  name text NOT NULL,
  items text[] NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.family_chores (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  kid_id uuid NOT NULL REFERENCES public.family_kids(id) ON DELETE CASCADE,
  title text NOT NULL,
  frequency text NOT NULL CHECK (frequency IN ('daily','weekly')),
  part_of_day text CHECK (part_of_day IN ('morning','afternoon','evening')),
  group_label text,
  pay numeric(8,2) NOT NULL DEFAULT 0 CHECK (pay >= 0),
  fine numeric(8,2) CHECK (fine IS NULL OR fine >= 0),
  checklist_id uuid REFERENCES public.family_checklists(id) ON DELETE SET NULL,
  sort_order int NOT NULL DEFAULT 0,
  active_from date NOT NULL DEFAULT ((now() AT TIME ZONE 'America/Chicago')::date),
  active_to date,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS family_chores_kid_idx ON public.family_chores(kid_id);

CREATE TABLE IF NOT EXISTS public.family_chore_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  chore_id uuid NOT NULL REFERENCES public.family_chores(id) ON DELETE CASCADE,
  kid_id uuid NOT NULL REFERENCES public.family_kids(id) ON DELETE CASCADE,
  occurrence_date date NOT NULL,
  status text NOT NULL CHECK (status IN ('claimed','verified','missed','false_claim','excused')),
  amount numeric(8,2) NOT NULL DEFAULT 0,
  note text,
  updated_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (chore_id, occurrence_date)
);
CREATE INDEX IF NOT EXISTS family_chore_log_kid_date_idx ON public.family_chore_log(kid_id, occurrence_date);

CREATE TABLE IF NOT EXISTS public.family_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  kid_id uuid NOT NULL REFERENCES public.family_kids(id) ON DELETE CASCADE,
  entry_date date NOT NULL DEFAULT ((now() AT TIME ZONE 'America/Chicago')::date),
  bucket text NOT NULL CHECK (bucket IN ('spend','tithe','invest')),
  kind text NOT NULL CHECK (kind IN ('payout','tithe_given','invested','bonus','adjustment')),
  amount numeric(8,2) NOT NULL,
  note text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS family_ledger_kid_idx ON public.family_ledger(kid_id);

-- Access: owner and manager only (Peter and Marie).
DO $pol$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['family_settings','family_kids','family_checklists','family_chores','family_chore_log','family_ledger'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_parents_all', t);
    EXECUTE format($f$CREATE POLICY %I ON public.%I FOR ALL TO authenticated
      USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = auth.uid() AND u.role IN ('owner','manager')))
      WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id = auth.uid() AND u.role IN ('owner','manager')))$f$, t || '_parents_all', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
  END LOOP;
END $pol$;

-- Sunday that starts the week holding d.
CREATE OR REPLACE FUNCTION public.family_week_start(d date)
RETURNS date LANGUAGE sql IMMUTABLE AS $$
  SELECT d - extract(dow FROM d)::int;
$$;

-- The fine for one chore: its own fine if set, else its pay, never below the family minimum.
CREATE OR REPLACE FUNCTION public.family_chore_fine(p_chore_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT COALESCE(c.fine, GREATEST(c.pay, COALESCE(s.min_fine, 0.25)))
  FROM public.family_chores c
  LEFT JOIN public.family_settings s ON s.agency_id = c.agency_id
  WHERE c.id = p_chore_id;
$$;

-- Dollar effect of a status. Done pays. Missed costs the fine.
-- A false claim costs the fine times the multiplier. Excused is zero.
CREATE OR REPLACE FUNCTION public.family_log_amount(p_chore_id uuid, p_status text)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT CASE p_status
    WHEN 'claimed'     THEN c.pay
    WHEN 'verified'    THEN c.pay
    WHEN 'missed'      THEN -public.family_chore_fine(c.id)
    WHEN 'false_claim' THEN -round(public.family_chore_fine(c.id) * COALESCE(s.false_claim_multiplier, 2), 2)
    ELSE 0 END
  FROM public.family_chores c
  LEFT JOIN public.family_settings s ON s.agency_id = c.agency_id
  WHERE c.id = p_chore_id;
$$;

-- Only writer of chore outcomes. p_status NULL clears the entry.
CREATE OR REPLACE FUNCTION public.family_set_status(p_chore_id uuid, p_occurrence_date date, p_status text, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER AS $$
DECLARE v_kid uuid; v_agency uuid; v_freq text; v_occ date; v_row public.family_chore_log;
BEGIN
  SELECT kid_id, agency_id, frequency INTO v_kid, v_agency, v_freq FROM public.family_chores WHERE id = p_chore_id;
  IF v_kid IS NULL THEN RAISE EXCEPTION 'chore not found'; END IF;
  v_occ := CASE WHEN v_freq = 'weekly' THEN public.family_week_start(p_occurrence_date) ELSE p_occurrence_date END;
  IF p_status IS NULL THEN
    DELETE FROM public.family_chore_log WHERE chore_id = p_chore_id AND occurrence_date = v_occ;
    RETURN jsonb_build_object('cleared', true);
  END IF;
  INSERT INTO public.family_chore_log (agency_id, chore_id, kid_id, occurrence_date, status, amount, note, updated_by)
  VALUES (v_agency, p_chore_id, v_kid, v_occ, p_status, public.family_log_amount(p_chore_id, p_status), p_note, auth.uid())
  ON CONFLICT (chore_id, occurrence_date) DO UPDATE
    SET status = EXCLUDED.status, amount = EXCLUDED.amount,
        note = COALESCE(EXCLUDED.note, public.family_chore_log.note),
        updated_by = EXCLUDED.updated_by, updated_at = now()
  RETURNING * INTO v_row;
  RETURN to_jsonb(v_row);
END $$;

-- Marks every past, unlogged chore as missed (with its fine).
-- Daily chores: any day before today. Weekly chores: any week that has fully ended.
-- Only counts dates on or after the kid's tracking start and inside the chore's active window.
CREATE OR REPLACE FUNCTION public.family_sweep_missed()
RETURNS int LANGUAGE plpgsql SECURITY INVOKER AS $$
DECLARE v_today date := (now() AT TIME ZONE 'America/Chicago')::date; n int;
BEGIN
  WITH occ AS (
    SELECT c.id AS chore_id, c.kid_id, c.agency_id, d::date AS occurrence_date
    FROM public.family_chores c
    JOIN public.family_kids k ON k.id = c.kid_id AND k.is_active
    CROSS JOIN LATERAL generate_series(GREATEST(k.tracking_start, c.active_from), LEAST(v_today - 1, COALESCE(c.active_to, v_today - 1)), interval '1 day') d
    WHERE c.frequency = 'daily'
    UNION ALL
    SELECT c.id, c.kid_id, c.agency_id, w::date
    FROM public.family_chores c
    JOIN public.family_kids k ON k.id = c.kid_id AND k.is_active
    CROSS JOIN LATERAL generate_series(
      public.family_week_start(GREATEST(k.tracking_start, c.active_from) + 6),
      public.family_week_start(v_today) - 7, interval '7 days') w
    WHERE c.frequency = 'weekly'
      AND (c.active_to IS NULL OR w::date <= c.active_to)
  ), ins AS (
    INSERT INTO public.family_chore_log (agency_id, chore_id, kid_id, occurrence_date, status, amount)
    SELECT o.agency_id, o.chore_id, o.kid_id, o.occurrence_date, 'missed', public.family_log_amount(o.chore_id, 'missed')
    FROM occ o
    ON CONFLICT (chore_id, occurrence_date) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO n FROM ins;
  RETURN n;
END $$;

-- Money per kid. Tithe and invest are set aside from each week's earnings
-- (pay credited, before fines), then reduced by money actually given or invested.
-- Spend = all chore amounts minus what was set aside, plus manual ledger entries.
CREATE OR REPLACE FUNCTION public.family_balances(p_week_start date DEFAULT NULL)
RETURNS TABLE (kid_id uuid, name text, spend numeric, tithe numeric, invest numeric,
               week_earned numeric, week_fines numeric, week_possible numeric)
LANGUAGE sql STABLE SECURITY INVOKER AS $$
  WITH wk AS (SELECT COALESCE(p_week_start, public.family_week_start((now() AT TIME ZONE 'America/Chicago')::date)) AS ws),
  weekly AS (
    SELECT l.kid_id, public.family_week_start(l.occurrence_date) AS ws,
           sum(l.amount) AS net, sum(GREATEST(l.amount, 0)) AS earned, sum(LEAST(l.amount, 0)) AS fines
    FROM public.family_chore_log l GROUP BY 1, 2
  ),
  set_aside AS (
    SELECT w.kid_id,
           sum(w.net) AS net,
           sum(round(w.earned * k.tithe_pct / 100, 2)) AS tithe,
           sum(round(w.earned * k.invest_pct / 100, 2)) AS invest
    FROM weekly w JOIN public.family_kids k ON k.id = w.kid_id GROUP BY 1
  ),
  led AS (
    SELECT kid_id,
           sum(amount) FILTER (WHERE bucket = 'spend')  AS spend,
           sum(amount) FILTER (WHERE bucket = 'tithe')  AS tithe,
           sum(amount) FILTER (WHERE bucket = 'invest') AS invest
    FROM public.family_ledger GROUP BY 1
  ),
  possible AS (
    SELECT c.kid_id, sum(c.pay * CASE WHEN c.frequency = 'daily' THEN 7 ELSE 1 END) AS amt
    FROM public.family_chores c, wk
    WHERE c.active_from <= wk.ws + 6 AND (c.active_to IS NULL OR c.active_to >= wk.ws)
    GROUP BY 1
  )
  SELECT k.id, k.name,
    COALESCE(sa.net, 0) - COALESCE(sa.tithe, 0) - COALESCE(sa.invest, 0) + COALESCE(led.spend, 0),
    COALESCE(sa.tithe, 0)  + COALESCE(led.tithe, 0),
    COALESCE(sa.invest, 0) + COALESCE(led.invest, 0),
    COALESCE(tw.earned, 0), COALESCE(tw.fines, 0), COALESCE(p.amt, 0)
  FROM public.family_kids k
  CROSS JOIN wk
  LEFT JOIN set_aside sa ON sa.kid_id = k.id
  LEFT JOIN led ON led.kid_id = k.id
  LEFT JOIN weekly tw ON tw.kid_id = k.id AND tw.ws = wk.ws
  LEFT JOIN possible p ON p.kid_id = k.id
  WHERE k.is_active
  ORDER BY k.sort_order;
$$;

GRANT EXECUTE ON FUNCTION public.family_week_start(date), public.family_chore_fine(uuid), public.family_log_amount(uuid, text),
  public.family_set_status(uuid, date, text, text), public.family_sweep_missed(), public.family_balances(date) TO authenticated;
