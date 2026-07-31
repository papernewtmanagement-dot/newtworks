-- Drop gmail_label_classification_map (dead table, 0 readers).
-- Drop bank_register_preliminary.gmail_label_applied (dead column on live table, 0 readers).
-- Classifier for incoming Gmail attachments is
-- document-processor/classifier.ts::classifyDocument — sender + subject + filename
-- regex only. Gmail label names never factor into routing.

DROP TABLE IF EXISTS public.gmail_label_classification_map;

ALTER TABLE public.bank_register_preliminary
  DROP COLUMN IF EXISTS gmail_label_applied;

COMMENT ON TABLE public.bank_register_preliminary IS
  'Preliminary bank register from statement ingest. Classifier: sender + subject + filename via document-processor/classifier.ts::classifyDocument. Gmail labels are not part of routing.';
