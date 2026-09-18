-- Fix: joining kept words with \s+ failed whenever the original had punctuation
-- between them ("sams club.com", "Team Budget: post-ramp"). Words are now joined
-- with [^A-Za-z]* so any punctuation, digits or spacing between them still matches.

CREATE OR REPLACE FUNCTION public.gl_pattern_from_description(p_description text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v text;
  v_tokens text[];
  v_keep text[] := ARRAY[]::text[];
  t text;
  v_letters int := 0;
BEGIN
  IF p_description IS NULL OR length(trim(p_description)) = 0 THEN
    RETURN NULL;
  END IF;

  v := upper(trim(p_description));

  -- channel prefixes that vary between statements for the same merchant
  v := regexp_replace(v, '^(POS |PURCHASE |DEBIT CARD |CHECKCARD |RECURRING PAYMENT |RECURRING |SQ \*|TST\* |PP\*|PAYPAL \*|WWW\.)', '', 'g');
  -- store numbers and reference ids
  v := regexp_replace(v, '#\s*[0-9]+', ' ', 'g');
  -- any word containing a digit (order numbers, dates, auth codes, card masks)
  v := regexp_replace(v, '\m[A-Z0-9]*[0-9][A-Z0-9]*\M', ' ', 'g');
  -- keep letters only; everything else becomes a separator
  v := regexp_replace(v, '[^A-Z]', ' ', 'g');
  v := regexp_replace(v, '\s+', ' ', 'g');
  v := trim(v);

  IF length(v) = 0 THEN
    RETURN NULL;
  END IF;

  v_tokens := string_to_array(v, ' ');
  FOREACH t IN ARRAY v_tokens LOOP
    IF length(t) >= 2 THEN
      v_keep := v_keep || t;
      v_letters := v_letters + length(t);
    END IF;
    EXIT WHEN COALESCE(array_length(v_keep, 1), 0) >= 3;
  END LOOP;

  -- too little to go on: a 3-letter pattern would match half the book
  IF v_letters < 4 THEN
    RETURN NULL;
  END IF;

  RETURN '(?i)' || array_to_string(v_keep, '[^A-Za-z]*');
END;
$$;
