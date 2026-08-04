-- Follow-up to hiregauge_construct_rename_capability_character_commitment.
-- The prose sweep in that migration ran two case-sensitive passes (Title case and
-- lower case) and therefore skipped ALL-CAPS occurrences. One row had "NURTURE"
-- inside a heading. Sweeping upper case explicitly rather than switching to a
-- case-insensitive replace, because a case-insensitive replace cannot preserve the
-- original casing of each match.

UPDATE public.hiregauge_rules
SET description = regexp_replace(regexp_replace(regexp_replace(
      COALESCE(description,''),
      '\yNATURE\y', 'CAPABILITY', 'g'), '\yNURTURE\y', 'CHARACTER', 'g'), '\yDRIVERS\y', 'COMMITMENT', 'g'),
    notes = regexp_replace(regexp_replace(regexp_replace(
      COALESCE(notes,''),
      '\yNATURE\y', 'CAPABILITY', 'g'), '\yNURTURE\y', 'CHARACTER', 'g'), '\yDRIVERS\y', 'COMMITMENT', 'g'),
    updated_at = now()
WHERE (COALESCE(description,'') || COALESCE(notes,'')) ~ '\y(NATURE|NURTURE|DRIVERS)\y';
