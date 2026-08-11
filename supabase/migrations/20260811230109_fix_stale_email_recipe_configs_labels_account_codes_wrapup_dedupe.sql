-- Audit follow-through 2026-08-11. Three stale-config faults in the email
-- pipeline, all found by auditing the recipe rows against the live Gmail label
-- set and the live chart of accounts.

-- ===========================================================================
-- 1. Time Off Vote — Email Reply Ingestor: archive labels
-- ===========================================================================
-- WAS: input_config.universal_archive_label_names =
--        ["Newtworks/TimeOff-VoteReplies", "Newtworks/Processed"]
-- Two separate faults stacked:
--   (a) WRONG KEY. automation-runner reads archive_label_ids_to_add. The key
--       universal_archive_label_names appears nowhere in the function — it is
--       not in RUNNER_ONLY_KEYS, so it was not even stripped before building
--       the Composio arguments; it was passed through to GMAIL_FETCH_EMAILS as
--       an unrecognised argument.
--   (b) DEAD VALUES. The Newtworks/ umbrella label was deleted in the
--       2026-07-29 reorg. "Newtworks/Processed" survives as Operations/Processed
--       (Label_5). "Newtworks/TimeOff-VoteReplies" never existed post-reorg.
-- Net effect: replies were archived (INBOX removed by archive_after_parse) but
-- never labelled, so they vanished into All Mail unfiled.
--
-- FIX: created Gmail label "Team/Time Off" (Label_32) — matches the live
-- taxonomy, which already nests Call Logs, Hiring, Payroll and Wrapups under
-- Team/. Both original labels are preserved in intent: the specific one is now
-- Label_32, the Processed one is Label_5. Dead key dropped.
UPDATE public.automation_recipes
SET input_config = (input_config - 'universal_archive_label_names')
                   || jsonb_build_object('archive_label_ids_to_add',
                                         jsonb_build_array('Label_32', 'Label_5')),
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND id = '005deb76-99f9-4d3a-afab-0e964133c06f';

-- ===========================================================================
-- 2. Monthly Close Checklist Generator: retired letter-prefixed account codes
-- ===========================================================================
-- Eight account_code values were still in the pre-numeric COA-* form. Zero of
-- them exist in chart_of_accounts (verified: SELECT ... WHERE account_code LIKE
-- 'COA-%' returns no rows), so every generated checklist row carried an account
-- code that resolves to nothing. Same dead-code class as the resolveSourceAccount
-- fault fixed in document-processor v107.
--
-- MAPPING, every one evidenced from the migration ledger, none guessed:
--   COA-006 -> 1011   _phase3_rekey_account, 20260730190000
--   COA-007 -> 1012   _phase3_rekey_account, 20260730190000
--   COA-010 -> 2115   _phase3_rekey_account, 20260730190000. NOTE: 2115 is
--                     "PSS — Capital One Personal Card (agency use)", NOT 2172
--                     "Personal — Capital One Personal (7435)". Two different
--                     Capital One accounts; the balance-review item is about the
--                     agency-use one.
--   COA-028 -> 2114   _phase3_rekey_account, 20260730190000
--   COA-013 -> 2113   "SF Card - Expenses, Alvi" (3439) was collapsed into
--                     3447 by 20260728190834_usbank_3447_collapse, which set
--                     alternate_last4s = ['4676','3439'] on the 3447 account.
--   COA-014 -> 2113   "SF Card - Expenses, Peter" (4676), same collapse.
--                     COA-013 and COA-014 therefore both point at ONE account
--                     now, so the two separate card items collapse into one.
--
-- TWO ITEMS DROPPED RATHER THAN REMAPPED — their targets do not exist:
--   COA-025 "USBank GN Personal Card" was hard-deleted 2026-07-28
--     (20260728165500_delete_bogus_usbank_gn_record) on Peter's directive that
--     the account and its $9,434.85 balance "does not exist". Carrying a close
--     item for a deleted account asks Peter to confirm a balance every month
--     for something already established as fictional.
--   COA-022 was "0006 PERSONAL", a profit-and-loss section header, not a bank
--     or card account. Neither 0005 nor 0006 exists in chart_of_accounts now
--     (0005 was deleted by 20260808193214_phase7_retire_account_0005). The
--     item's own label said "0005 PERSONAL (COA-022)" — name and code already
--     disagreed with each other before this.
UPDATE public.automation_recipes
SET input_config = jsonb_set(
      jsonb_set(
        input_config,
        '{items}',
        (
          SELECT jsonb_agg(
            CASE
              WHEN item->>'account_code' = 'COA-007'
                THEN jsonb_set(item, '{account_code}', '"1012"')
              WHEN item->>'account_code' = 'COA-006'
                THEN jsonb_set(item, '{account_code}', '"1011"')
              WHEN item->>'account_code' = 'COA-014'
                THEN jsonb_set(
                       jsonb_set(item, '{account_code}', '"2113"'),
                       '{doc_label}',
                       '"US Bank Business Cash Rewards (3447) — card statement"')
              ELSE item
            END
            ORDER BY ord
          )
          FROM jsonb_array_elements(input_config->'items') WITH ORDINALITY AS t(item, ord)
          -- COA-013 dropped: same account as COA-014 after the 3447 collapse.
          WHERE coalesce(item->>'account_code', '') <> 'COA-013'
        )
      ),
      '{balance_review_items}',
      (
        SELECT coalesce(jsonb_agg(
          CASE
            WHEN item->>'account_code' = 'COA-028'
              THEN jsonb_set(
                     jsonb_set(item, '{account_code}', '"2114"'),
                     '{doc_label}',
                     '"Confirm balance: CITI Personal Card, agency use (2114) — carry until CPA adjusts"')
            WHEN item->>'account_code' = 'COA-010'
              THEN jsonb_set(
                     jsonb_set(item, '{account_code}', '"2115"'),
                     '{doc_label}',
                     '"Confirm balance: Capital One Personal Card, agency use (2115) — carry until CPA adjusts"')
            ELSE item
          END
          ORDER BY ord
        ), '[]'::jsonb)
        FROM jsonb_array_elements(input_config->'balance_review_items') WITH ORDINALITY AS t(item, ord)
        WHERE coalesce(item->>'account_code', '') NOT IN ('COA-022', 'COA-025')
      )
    ),
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND id = '99ce2d14-0d13-4ed9-9729-fdbb35fd63d1';

-- ===========================================================================
-- 3. Weekly Wrapup Ingest: three recipes, two of them redundant
-- ===========================================================================
-- All three ran identical input_config {"mode":"wrapup"} and only differed by
-- cron. The repeat ticks ARE intentional — teammates send wrap-ups at
-- unpredictable times through Friday and Saturday and the nag flow depends on
-- re-checking — so the schedules are kept in full. What was wrong was carving
-- one day's coverage across two rows with near-identical names ("Fri 7 PM" vs
-- "Friday PM"), which is how a schedule gap gets introduced later by someone
-- editing the wrong row.
--
-- Friday coverage merged into one row: 15:00-18:30 every 30 min (aac0ba70) plus
-- the standalone 19:00 tick (8dd473dc) becomes 15:00-19:30 every 30 min. That
-- is a superset of both — no window lost, two extra ticks gained (19:30, and
-- 19:00 was already covered).
UPDATE public.automation_recipes
SET recipe_name = 'Weekly Wrapup Ingest — Friday',
    cron_expression = '0,30 15-19 * * 5',
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND id = 'aac0ba70-f648-47d5-84fe-197a7cc26af3';

-- Superseded row deactivated rather than deleted: Peter did not say delete, and
-- automation_run_log rows reference recipe_id, so keeping the row keeps that
-- history resolvable. Renamed so it can never be mistaken for live config.
UPDATE public.automation_recipes
SET recipe_name = 'Weekly Wrapup Ingest — Fri 7 PM (SUPERSEDED 2026-08-11, folded into Friday recipe)',
    is_active = false,
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND id = '8dd473dc-8fe3-46aa-b789-1ff93aadb140';

UPDATE public.automation_recipes
SET recipe_name = 'Weekly Wrapup Ingest — Saturday',
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND id = '994aa993-72fa-43ce-ad28-873d95cd555a';
