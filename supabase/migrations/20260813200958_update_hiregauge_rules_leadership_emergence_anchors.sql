-- Resume scoring revamp: Leadership Emergence anchors rewritten to tenure-relative pace
-- Approved spec: session_note "2026-08-12 — Resume scoring revamp: approved spec
-- (signal-level weights + LE anchors + autonomy imputation)"

UPDATE public.hiregauge_rules
SET
  trait_signature = jsonb_set(
    trait_signature,
    '{anchors}',
    '{
      "0": "No advancement regardless of tenure, or downward moves only.",
      "30": "Slow relative to tenure — first promotion only after many years (e.g. one promotion in 8-10 years), or a long career with rare advancement.",
      "50": "Typical pace — advancement roughly in line with normal career timelines (e.g. 2-3 promotions across 10-15 years, still line-level).",
      "70": "Fast relative to tenure — promoted within the first 1-2 years of a role, especially a first job, or reached supervisor/manager within 5-7 years with multiple promotions.",
      "100": "Very fast — promoted within months of starting, or sustained rapid advancement across a career."
    }'::jsonb
  ),
  description = description
    || E'\n\nADVANCEMENT SPEED (added 2026-08-12): Always judge advancement speed relative to tenure, not raw promotion count. One promotion in a candidate''s first year is stronger evidence than one promotion in ten, even though both resumes show ''one promotion''.'
    || E'\n\nEMPLOYER STRUCTURE (added 2026-08-12): Judge speed in the context of the employer''s structure — a 3-person shop offers fewer rungs than a chain restaurant; weigh named leadership selection (team lead, trainer, shift lead) accordingly.',
  updated_at = now()
WHERE id = 'a304362f-6a7c-4370-b581-097550e21b6a';
