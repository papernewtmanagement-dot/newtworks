-- Split rules (Peter 2026-09-26). One bank or card line can now book in parts: a rule keeps its own
-- account for the remainder, and gl_rule_splits lists fixed-amount parts that go elsewhere.
-- First use: the monthly State Farm charge (~$230) covers four policies. $140 (Rav4 $76.12 + umbrella
-- $59.83, rounded per Peter) goes to PaperNewt; the rest (business policy + workers comp) stays on the agency.
CREATE TABLE IF NOT EXISTS public.gl_rule_splits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  rule_id uuid NOT NULL REFERENCES public.gl_classification_rules(id) ON DELETE CASCADE,
  account_code text NOT NULL,
  target_business_entity_id uuid NOT NULL REFERENCES public.business_entities(id),
  fixed_amount numeric NOT NULL CHECK (fixed_amount > 0),
  label text,
  sort_order int NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.gl_rule_splits ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS gl_rule_splits_agency ON public.gl_rule_splits;
CREATE POLICY gl_rule_splits_agency ON public.gl_rule_splits FOR ALL TO authenticated
  USING (agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid()))
  WITH CHECK (agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid()));
COMMENT ON TABLE public.gl_rule_splits IS 'Fixed-amount parts of a gl_classification_rule. The rule''s own account takes the remainder. Read by gl_rule_split_parts(); statement_gl_writer books one ledger row per part.';

CREATE OR REPLACE FUNCTION public.gl_rule_split_parts(p_agency_id uuid, p_rule_id uuid, p_amount numeric)
 RETURNS TABLE(account_id uuid, part_amount numeric, label text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  -- The fixed parts of a split rule. The rule's own account takes whatever is left.
  -- Returns nothing when the parts would reach the whole line (a small refund, a lower premium)
  -- or when a part's account does not resolve, so the line then books whole to the rule's account.
  WITH parts AS (
    SELECT s.fixed_amount, s.label, s.sort_order,
      (SELECT c.id FROM public.chart_of_accounts c
        WHERE c.agency_id = s.agency_id AND c.account_code = s.account_code
          AND c.business_entity_id = s.target_business_entity_id AND c.is_active
        LIMIT 1) AS acct
    FROM public.gl_rule_splits s
    WHERE s.agency_id = p_agency_id AND s.rule_id = p_rule_id
  )
  SELECT acct, fixed_amount, label FROM parts
  WHERE (SELECT sum(fixed_amount) FROM parts) < abs(p_amount)
    AND NOT EXISTS (SELECT 1 FROM parts WHERE acct IS NULL)
  ORDER BY sort_order;
$function$;
REVOKE ALL ON FUNCTION public.gl_rule_split_parts(uuid, uuid, numeric) FROM PUBLIC, anon;

DO $mig$
DECLARE
  v_def text := pg_get_functiondef('public.statement_gl_writer(uuid,uuid,date,date,boolean,uuid[])'::regprocedure);
  a_old text := $a$  v_count_skipped_excluded int := 0;
BEGIN
$a$;
  a_new text := $a$  v_count_skipped_excluded int := 0;
  v_split_total numeric := 0;
BEGIN
$a$;
  b_old text := $b$    IF v_claim_ledger_id IS NOT NULL THEN
      v_count_claimed := v_count_claimed + 1;$b$;
  b_new text := $b$    -- Split rules (2026-09-26): a rule with gl_rule_splits parts books the line in pieces. A claimed
    -- cash-register guess is taken out and the line is booked fresh from the statement, in parts.
    v_split_total := 0;
    IF v_rule_id IS NOT NULL AND v_classification_status = 'classified' THEN
      SELECT COALESCE(sum(sp.part_amount), 0) INTO v_split_total
      FROM gl_rule_split_parts(p_agency_id, v_rule_id, abs(v_amount)) sp;
    END IF;
    IF v_split_total > 0 AND v_claim_ledger_id IS NOT NULL THEN
      IF NOT p_dry_run THEN
        DELETE FROM ledger WHERE id = v_claim_ledger_id;
        UPDATE cash_register_preliminary
        SET coding_status = 'statement_confirmed', status = 'reconciled', reconciled_at = NOW(),
            reconciled_journal_entry_id = NULL,
            coding_question = 'The statement confirmed this charge and a split rule booked it in parts.',
            updated_at = NOW()
        WHERE id = v_claim_register_id;
      END IF;
      v_claim_ledger_id := NULL;
    END IF;

    IF v_claim_ledger_id IS NOT NULL THEN
      v_count_claimed := v_count_claimed + 1;$b$;
  c_old text := $c$        CASE WHEN v_direction = 'debit' THEN abs(v_amount) ELSE 0 END,
        CASE WHEN v_direction = 'credit' THEN abs(v_amount) ELSE 0 END,
        v_description, 'statement_gl_writer',$c$;
  c_new text := $c$        CASE WHEN v_direction = 'debit' THEN abs(v_amount) - v_split_total ELSE 0 END,
        CASE WHEN v_direction = 'credit' THEN abs(v_amount) - v_split_total ELSE 0 END,
        v_description, 'statement_gl_writer',$c$;
  d_old text := $d$        'statement_txn'
      );
    END IF;
  END LOOP;$d$;
  d_new text := $d$        'statement_txn'
      );
      IF v_split_total > 0 THEN
        INSERT INTO ledger (
          agency_id, entry_date, account_id, debit, credit, description,
          source, reference_number, statement_id, rule_id_used, classification_status,
          classified_by, classified_at, entry_type
        )
        SELECT p_agency_id, v_txn_date, sp.account_id,
               CASE WHEN v_direction = 'debit' THEN sp.part_amount ELSE 0 END,
               CASE WHEN v_direction = 'credit' THEN sp.part_amount ELSE 0 END,
               v_description || ' — ' || COALESCE(sp.label, 'split part'),
               'statement_gl_writer', v_reference_number, v_stmt_id, v_rule_id, 'classified',
               'rule:' || v_rule_id::text || ':split', NOW(), 'statement_txn'
        FROM gl_rule_split_parts(p_agency_id, v_rule_id, abs(v_amount)) sp;
      END IF;
    END IF;
  END LOOP;$d$;
BEGIN
  IF (length(v_def) - length(replace(v_def, a_old, ''))) / length(a_old) <> 1 THEN RAISE EXCEPTION 'anchor A'; END IF;
  IF (length(v_def) - length(replace(v_def, b_old, ''))) / length(b_old) <> 1 THEN RAISE EXCEPTION 'anchor B'; END IF;
  IF (length(v_def) - length(replace(v_def, c_old, ''))) / length(c_old) <> 1 THEN RAISE EXCEPTION 'anchor C'; END IF;
  IF (length(v_def) - length(replace(v_def, d_old, ''))) / length(d_old) <> 1 THEN RAISE EXCEPTION 'anchor D'; END IF;
  EXECUTE replace(replace(replace(replace(v_def, a_old, a_new), b_old, b_new), c_old, c_new), d_old, d_new);
END $mig$;
