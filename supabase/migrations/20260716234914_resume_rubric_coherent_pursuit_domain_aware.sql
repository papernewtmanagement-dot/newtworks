UPDATE public.hiregauge_rules
SET trait_signature = jsonb_set(
  trait_signature,
  '{markers_positive}',
  '["one industry or skill stack pursued consistently over 3+ years", "late-career pivot after long tenure OK (single coherent pivot into adjacent domain)", "clear directional theme across employers", "durable domain throughline (5+ years in one domain) even without upward moves", "throughline TOWARD consultative / customer-facing / sales / advisory work scores HIGHER (target-domain adjacent)", "throughline in off-target domain (warehouse, back-office, purely technical) is durable-but-not-target-relevant — score MID even if consistent"]'::jsonb
),
    description = 'Consistency of directional pursuit across the trailing 3 years, with domain-awareness. Throughline toward consultative/customer-facing work scores higher than throughline in off-target domain. Parser weight: 1 of 3 sub-signals averaged for Drivers.',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_type = 'resume_score_rubric'
  AND short_label = 'Coherent Pursuit';

-- Add explicit note in Config row that Trajectory Direction stays domain-neutral,
-- Coherent Pursuit + Interpersonal Substrate carry all domain-fit signal.
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_set(
      trait_signature,
      '{domain_awareness_note}',
      '"Domain-fit signal is carried by TWO sub-signals: Interpersonal Substrate (Nature) rewards sustained people-facing / consultative / relational work; Coherent Pursuit (Drivers) rewards throughline toward consultative / customer-facing / sales work. Trajectory Direction stays domain-neutral (any upward movement counts). Do not add domain-awareness to other sub-signals — would double-count."'::jsonb
    ),
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_type = 'resume_score_rubric'
  AND short_label = 'Composite Config';;