-- The fallback Drive folder pointer died again.
--
-- 2026-08-09 (migration 20260809055838) repointed drive_newtworks_root_folder_id
-- at 1O9eR3wuNc5mGzZIZPE-1X9l_H52oehm6 precisely because the prior value was a
-- folder Peter had deleted in the Drive reorg. Checked live 2026-08-11: that
-- replacement folder is ALSO gone ("Requested entity was not found"), so the
-- setting has been dead again for at least two days.
--
-- WHAT IT CONTROLS: document-processor's documentFolderId() falls back to this
-- value for any document with no per-account folder (accounts.drive_folder_id)
-- and no fixed type folder — i.e. commission_report, team_production,
-- archive_bundle, skip, and any bank/credit account not yet mapped (today that
-- is 2114 only). The code does resolveDriveFolder("Documents", <this value>),
-- so this setting is the PARENT the "Documents" tree gets built inside, not the
-- Documents folder itself. Pointing it AT a folder named Documents would
-- produce Documents/Documents/<year-month>/<type>.
--
-- WHY MY DRIVE ROOT AND NOT A NEW FOLDER: the live top level is Accounts,
-- Brand, Comp - Deduct, Marketing, QBO Reports, Reference, Team, Teaching -
-- Consumer Math. Every other routing target in this system is a top-level
-- folder, so the fallback tree belongs at the same level rather than nested
-- inside a purpose-named folder it does not belong to. There is a stray
-- "Documents" folder (1FreHkVMnrupDLV0UU5q5G4NzGQthLfCF, created 2026-08-04)
-- that is NOT at top level — it was almost certainly inside the root that got
-- deleted. Deliberately not adopted: reaching into an orphaned folder is how
-- the last two dead pointers happened.
--
-- VERIFIED BEFORE APPLYING: GOOGLEDRIVE_FIND_FOLDER at the pinned tool version
-- 20260721_00 accepts 0AD68TbreqCgWUk9PVA as parent_folder_id and correctly
-- returned the "Accounts" folder. The My Drive root ID is a usable parent, so
-- find-or-create of "Documents" underneath it will work on first fallback use.
--
-- Low blast radius by design: this path has been exercised exactly once since
-- 2026-08-09, so this is closing a landmine rather than stopping active loss.

UPDATE public.settings
SET setting_value = '0AD68TbreqCgWUk9PVA',
    description = 'Google Drive parent folder that the fallback document tree is built inside: <this folder>/Documents/<year-month>/<doc type>. Currently the My Drive root, so the Documents tree sits at top level alongside Accounts, Team, Comp - Deduct etc. Read by document-processor documentFolderId() ONLY for doc types with no per-account folder (accounts.drive_folder_id) and no fixed type folder — commission_report, team_production, archive_bundle, skip, and any unmapped bank/credit account. NOTE this is the PARENT, not the Documents folder itself. Repointed 2026-08-11: the two prior values were both folders that had been deleted, leaving the fallback dead.',
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND setting_key = 'drive_newtworks_root_folder_id';
