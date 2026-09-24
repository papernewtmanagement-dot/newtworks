-- Drive filing homes for document-processor, 2026-09-23.
--
-- WHY: resumes piled up at the top of Google Drive twice. Resumes, CTS results
-- and PFA statements had no fixed folder, so they fell into the
-- Documents/<month>/<type> tree built under drive_newtworks_root_folder_id,
-- which migration 20260811202011 had pointed at the top of Drive on purpose.
-- Peter ruled (2026-09-02) that loose resumes live in Team > Hiring > Resumes,
-- and (2026-09-23, decision 2A) that nothing should ever land at the top.
--
-- WHAT: one settings row per fixed home, read once by loadDriveFolders() and
-- mapped by FIXED_DRIVE_FOLDER in supabase/functions/document-processor/index.ts
-- (commits d245e7e5, d71d5039). The first three rows were inserted earlier the
-- same day by hand; repeated here with WHERE NOT EXISTS so the ledger holds the
-- whole set. The fallback root moves from the top of Drive to Operations, so a
-- document type with no home files under Operations > Documents > <month> >
-- <type>. This supersedes the "why My Drive root" reasoning in 20260811202011.

INSERT INTO public.settings (agency_id, setting_key, setting_value, setting_type, description, updated_by, updated_at, created_at)
SELECT '126794dd-25ff-47d2-a436-724499733365', v.k, v.val, 'string', v.d, 'claude_conversation', now(), now()
FROM (VALUES
 ('drive_hiring_resumes_folder_id','1rT1rGwJdIhlBntcRBLZDYVP07M_qz0vG','Google Drive folder Team > Hiring > Resumes. document-processor files every resume (resume_manual_batch, careerplug_applicant) here, and the text-recognition copy of a scanned resume goes here too. Peter ruling 2026-09-02: loose resumes live in Team > Hiring > Resumes. Wired 2026-09-23 (FIXED_DRIVE_FOLDER in document-processor).'),
 ('drive_hiring_cts_folder_id','1UuJBEpfWqYLhQt4rSZOcjYZDTaJe7PPs','Google Drive folder Team > Hiring > CTS Profiles. document-processor files CTS result PDFs (cts_profile) here. Wired 2026-09-23 (FIXED_DRIVE_FOLDER in document-processor).'),
 ('drive_pfa_folder_id','1Iu890PieqgSKOv3LDsF34ybGkZ03fdSG','Google Drive folder Accounts > Bank > 5816 FRST - Agency PFA. document-processor files PFA statements (bank_statement_pfa) here. Created and wired 2026-09-23 (FIXED_DRIVE_FOLDER in document-processor).'),
 ('drive_accounts_folder_id','1BZhcUtqSfpH4dCFj9VYCxthTmSxL1xjY','Google Drive folder Accounts (top level). document-processor files zip bundles (archive_bundle) here. Peter decision 2A, 2026-09-23 (FIXED_DRIVE_FOLDER in document-processor).'),
 ('drive_team_folder_id','1SEYwf6UbnYRoRPvzXZ8Z8iOjDRSvtcS_','Google Drive folder Team (top level). document-processor files team production reports (team_production) here. Peter decision 2A, 2026-09-23 (FIXED_DRIVE_FOLDER in document-processor).')
) v(k, val, d)
WHERE NOT EXISTS (
  SELECT 1 FROM public.settings s
  WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.setting_key = v.k
);

UPDATE public.settings
SET setting_value = '1bNePc7Np6ACtWJlh5u4KXRS252oBN9f3',
    description = 'Google Drive folder the fallback document tree is built inside: <this folder>/Documents/<year-month>/<doc type>. Currently Operations (top-level folder). Read by document-processor documentFolderId() ONLY for doc types with no per-account folder (accounts.drive_folder_id) and no entry in FIXED_DRIVE_FOLDER, e.g. a bank or card account not yet mapped. NOTE this is the PARENT, not the Documents folder itself. Moved off the top of Drive 2026-09-23 (Peter decision 2A: nothing lands at the top of Drive); was 0AD68TbreqCgWUk9PVA (My Drive root) per 20260811202011.',
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND setting_key = 'drive_newtworks_root_folder_id';
