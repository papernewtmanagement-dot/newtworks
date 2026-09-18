-- v3. Two fixes found by running every ledger description through v2:
--  1. Reference codes run straight into the words after them
--     ("AMAZON MKTPL*TA4YW4JB3Amzn.com/billWA"), so dropping the code left
--     words the pattern could no longer reach. Bank descriptions put the
--     merchant first and the reference and location after, so the text is now
--     cut at the first word containing a digit.
--  2. Web and company suffixes (COM, WWW, LLC, INC) are noise, not merchant
--     name, and are dropped.
-- Words are joined with a short any-character gap so punctuation and spacing
-- differences between statements do not break the match.

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
  c_noise text[] := ARRAY['COM','WWW','NET','ORG','HTTP','HTTPS','LLC','INC','LTD','CORP','CO'];
BEGIN
  IF p_description IS NULL OR length(trim(p_description)) = 0 THEN
    RETURN NULL;
  END IF;

  v := upper(trim(p_description));

  -- channel prefixes that vary between statements for the same merchant
  v := regexp_replace(v, '^(POS |PURCHASE |DEBIT CARD |CHECKCARD |RECURRING PAYMENT |RECURRING |SQ ?\*|TST ?\*|PP ?\*|PAYPAL ?\* )', '', 'g');
  -- store numbers
  v := regexp_replace(v, '#\s*[0-9]+', ' ', 'g');
  -- everything from the first word containing a digit onward is reference and
  -- location text, not merchant name
  v := regexp_replace(v, '\m[A-Z0-9]*[0-9].*$', ' ', '');
  -- keep letters only; everything else becomes a separator
  v := regexp_replace(v, '[^A-Z]', ' ', 'g');
  v := regexp_replace(v, '\s+', ' ', 'g');
  v := trim(v);

  IF length(v) = 0 THEN
    RETURN NULL;
  END IF;

  v_tokens := string_to_array(v, ' ');
  FOREACH t IN ARRAY v_tokens LOOP
    IF length(t) >= 2 AND NOT (t = ANY(c_noise)) THEN
      v_keep := v_keep || t;
      v_letters := v_letters + length(t);
    END IF;
    EXIT WHEN COALESCE(array_length(v_keep, 1), 0) >= 3;
  END LOOP;

  -- too little to go on: a short pattern would match half the book
  IF v_letters < 4 THEN
    RETURN NULL;
  END IF;

  RETURN '(?i)' || array_to_string(v_keep, '.{0,24}?');
END;
$$;
