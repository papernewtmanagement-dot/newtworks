CREATE TABLE IF NOT EXISTS public.agency_snapshot (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id       uuid NOT NULL REFERENCES public.agency(id),
  snapshot_date   date NOT NULL,
  cadence         text NOT NULL CHECK (cadence IN ('monthly','weekly','ad-hoc')),

  auto_new_ytd       integer,
  auto_lost_ytd      integer,
  auto_pif           integer,
  auto_premium       numeric,

  fire_new_ytd       integer,
  fire_lost_ytd      integer,
  fire_pif           integer,
  fire_premium       numeric,

  life_new_ytd                integer,
  life_lost_ytd               integer,
  life_pif                    integer,
  life_paid_for_count_ytd     integer,
  life_paid_for_premium_ytd   numeric,
  life_premium                numeric,

  ips_new_money_ytd           numeric,

  household_count             integer,

  source       text NOT NULL,
  notes        text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),

  UNIQUE (agency_id, snapshot_date, cadence)
);

INSERT INTO public.agency_snapshot
  (id, agency_id, snapshot_date, cadence,
   auto_pif, auto_premium,
   fire_pif, fire_premium,
   life_pif, life_premium,
   household_count,
   source, notes, created_at, updated_at)
SELECT
  id, agency_id, snapshot_date, cadence,
  auto_pif, auto_premium,
  fire_pif, fire_premium,
  life_pif, life_premium,
  household_count,
  source, notes, created_at, updated_at
FROM public.book_snapshot
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.agency_snapshot a
SET auto_new_ytd               = s.auto_production_ytd,
    auto_lost_ytd              = s.auto_lapse_ytd,
    fire_new_ytd               = s.fire_production_ytd,
    fire_lost_ytd              = s.fire_lapse_ytd,
    life_new_ytd               = s.life_production_ytd,
    life_lost_ytd              = s.life_loss_ytd,
    life_paid_for_count_ytd    = s.life_paid_count_ytd,
    life_paid_for_premium_ytd  = s.life_premium_credits_ytd,
    ips_new_money_ytd          = s.ips_activity_ytd,
    notes = COALESCE(a.notes,'') || E'\n\n[YTD data merged from sf_on_time_snapshot ' ||
            s.snapshot_date::text || ': ' || COALESCE(s.notes,'') || ']',
    updated_at = now()
FROM public.sf_on_time_snapshot s
WHERE a.agency_id = s.agency_id
  AND s.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND a.snapshot_date = DATE '2026-06-13'
  AND a.cadence = 'weekly';

DO $$
DECLARE
  n_book   int;
  n_new    int;
  n_merged int;
BEGIN
  SELECT COUNT(*) INTO n_book FROM public.book_snapshot
    WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';
  SELECT COUNT(*) INTO n_new FROM public.agency_snapshot
    WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';
  SELECT COUNT(*) INTO n_merged FROM public.agency_snapshot
    WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
      AND snapshot_date = DATE '2026-06-13'
      AND auto_new_ytd IS NOT NULL;
  IF n_new <> n_book THEN
    RAISE EXCEPTION 'Row count mismatch: book_snapshot=% / agency_snapshot=%', n_book, n_new;
  END IF;
  IF n_merged <> 1 THEN
    RAISE EXCEPTION 'YTD merge failed: expected 1 row with auto_new_ytd populated, got %', n_merged;
  END IF;
  RAISE NOTICE 'Phase 1 verified: % rows copied, YTD merge applied to 2026-06-13', n_new;
END $$;
