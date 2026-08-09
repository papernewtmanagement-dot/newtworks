-- The two tolerant card-payment rules added minutes earlier never matched anything: they
-- used \b for a word boundary, which Postgres reads as a backspace character. Postgres
-- spells word boundary \y. Corrected below and verified against the live description corpus
-- before applying: the bank-side pattern matches all seven Capital One payment wordings and
-- does NOT match Amazon Marketplace PMTS, the CPS utility WEBPMT bill, IRS USATAXPYMT or the
-- U.S. Bank WEB PYMT rows. The card-side pattern matches all eight payment wordings seen on
-- card statements and does NOT match promo credits, cash-back rewards, credit adjustments or
-- any merchant refund.
--
-- Also drops the two broken rules rather than leaving dead regexes in the table.

DELETE FROM public.gl_classification_rules
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_name IN (
    'Capital One card payment from bank (tolerant PMT/PYMT/PAYMENT)',
    'SKIP — payment received onto a card (tolerant PMT/PYMT/PAYMENT)'
  );

INSERT INTO public.gl_classification_rules
  (agency_id, rule_name, match_priority, match_payee_regex, match_direction,
   debit_account_code, credit_account_code, confidence, source, is_active)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365',
   'Capital One card payment from bank (tolerant PMT/PYMT/PAYMENT)',
   20,
   '(?i)capital\s*one\y.{0,30}?(online|mobile|web|internet)?\W*(pmt|pymt|payment)',
   'debit', '2172', '__SOURCE__', 'high', 'manual', TRUE),
  ('126794dd-25ff-47d2-a436-724499733365',
   'SKIP — payment received onto a card (tolerant PMT/PYMT/PAYMENT)',
   20,
   '(?i)(online|mobile|web|internet|electronic)\W*(banking\W*)?(pmt|pymt|payment)|(pmt|pymt|payment)\W*(thank\s*you)',
   'credit', '__SKIP__', '__SKIP__', 'high', 'manual', TRUE);
