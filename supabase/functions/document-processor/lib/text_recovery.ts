// =========================================================================
// lib/text_recovery.ts
// =========================================================================
// Recovers readable text from a scanned or photographed file that carries no
// extractable text of its own.
//
// WHY THIS EXISTS (2026-08-04):
//   Roughly one in five hand-forwarded resumes is a scan or a phone photo
//   saved as a PDF. Those files have page images and no text layer, so the
//   normal extraction step returns nothing and the resume fails with no
//   candidate row — a real applicant who never enters the system. At one in
//   five, hand entry is a permanent tax.
//
// WHY THIS SHAPE:
//   Google Drive performs text recognition when a page-image file is brought
//   in AS a Google Doc. That costs nothing beyond the Drive account already
//   connected, needs no new vendor and no per-file charge, and the recovered
//   text feeds the existing identity step unchanged.
//
//   An earlier plan assumed these files were already sitting in Drive and
//   could simply be converted in place. They are not: checked live on
//   2026-08-04, none of the 143 forwarded resumes ever got a Drive copy,
//   because the upload step returns quietly on failure. So this brings the
//   file in from Gmail rather than converting something already there.
//
// THE CHAIN, three calls:
//   1. Ask Gmail for the attachment. It answers with a temporary signed link,
//      not the bytes. The link is good for an hour.
//   2. Hand that link to Drive as an upload, naming the target type as a
//      Google Doc. Naming the Doc type is what triggers text recognition.
//      Drive fetches the link on its own servers, so the file never travels
//      through this function.
//   3. Read the new document back as plain text.
//
// The converted document is deliberately KEPT, not deleted. It becomes the
// Drive copy these resumes have always been missing, and the caller writes
// its id onto the documents row.
// =========================================================================

// deno-lint-ignore-file no-explicit-any

import { callComposio } from "./composio.ts";

/** Everything this module needs to reach Gmail and Drive. */
export interface TextRecoveryDeps {
  composioApiKey: string;
  composioUserId: string;
  gmailAccountId: string;
  driveAccountId: string | null;
  /** Optional Drive folder to file the converted document in. Null = My Drive root. */
  driveParentFolderId?: string | null;
}

export type TextRecoveryResult =
  | {
      ok: true;
      text: string;
      driveFileId: string;
      driveUrl: string;
      charCount: number;
    }
  | { ok: false; error: string; stage: "gmail" | "convert" | "read" };

/** The Drive type that forces text recognition on a page-image file. */
const DRIVE_DOC_MIME = "application/vnd.google-apps.document";

/** Shortest recovered text we will treat as a real result. */
const MIN_USEFUL_CHARS = 40;

function stripExtension(fileName: string): string {
  return fileName.replace(/\.[A-Za-z0-9]{1,6}$/, "").trim() || fileName;
}

/**
 * Pull the temporary signed link out of a Composio response, tolerating the
 * two nesting shapes the wrapper can hand back.
 */
function signedLink(data: any, key: "file" | "downloaded_file_content"): string | null {
  const holder = data?.[key] ?? data?.data?.[key];
  const url = holder?.s3url;
  return typeof url === "string" && url.length > 0 ? url : null;
}

/**
 * Recover text from one scanned file.
 *
 * Every failure is reported with the stage it happened in, so a run that goes
 * wrong says whether Gmail, the conversion, or the read broke — the three have
 * completely different fixes.
 */
export async function recoverTextFromScannedFile(opts: {
  deps: TextRecoveryDeps;
  messageId: string;
  attachmentId: string;
  fileName: string;
}): Promise<TextRecoveryResult> {
  const { deps, messageId, attachmentId, fileName } = opts;

  if (!deps.driveAccountId) {
    return { ok: false, stage: "convert", error: "no Drive account connected, cannot run text recognition" };
  }
  if (!messageId || !attachmentId) {
    return {
      ok: false,
      stage: "gmail",
      error: "no Gmail message id or attachment id on this file, so the original cannot be fetched again",
    };
  }

  // ---- 1. Fresh signed link from Gmail ---------------------------------
  // It must be fresh: Drive fetches this link itself, and the link expires
  // after an hour. Reusing one captured earlier in a long run will fail.
  const gm = await callComposio({
    apiKey: deps.composioApiKey,
    userId: deps.composioUserId,
    connectedAccountId: deps.gmailAccountId,
    toolSlug: "GMAIL_GET_ATTACHMENT",
    toolArguments: {
      message_id: messageId,
      attachment_id: attachmentId,
      file_name: fileName,
      user_id: "me",
    },
  });
  if (!gm.ok) {
    return { ok: false, stage: "gmail", error: `GMAIL_GET_ATTACHMENT failed: ${gm.error}` };
  }
  const sourceUrl = signedLink(gm.data, "file");
  if (!sourceUrl) {
    return { ok: false, stage: "gmail", error: "Gmail returned no download link for the attachment" };
  }

  // ---- 2. Bring it into Drive AS a Google Doc --------------------------
  // Not every Drive tool is reachable from this function's Composio key: the
  // first choice below answered "Tool not found" on 2026-08-04 even though it
  // works from an interactive session, so more than one shape is attempted and
  // the winner is reported. Whichever runs, the point is the same — naming the
  // Google Docs type as the target is what makes Drive read the page images.
  const attempts: Array<{ slug: string; args: Record<string, unknown> }> = [
    {
      slug: "GOOGLEDRIVE_UPLOAD_FROM_URL",
      args: {
        source_url: sourceUrl,
        name: stripExtension(fileName),
        mime_type: DRIVE_DOC_MIME,
        ...(deps.driveParentFolderId ? { parent_folder_id: deps.driveParentFolderId } : {}),
      },
    },
    {
      slug: "GOOGLEDRIVE_CREATE_FILE_FROM_URL",
      args: {
        file_url: sourceUrl,
        file_name: stripExtension(fileName),
        mime_type: DRIVE_DOC_MIME,
        ...(deps.driveParentFolderId ? { parent_folder_id: deps.driveParentFolderId } : {}),
      },
    },
    {
      slug: "GOOGLEDRIVE_UPLOAD_FILE",
      args: {
        file_name: stripExtension(fileName),
        file_path: sourceUrl,
        mime_type: DRIVE_DOC_MIME,
        ...(deps.driveParentFolderId ? { parent_folder_id: deps.driveParentFolderId } : {}),
      },
    },
  ];

  let driveFileId = "";
  let driveUrl = "";
  let usedSlug = "";
  const convertErrors: string[] = [];

  for (const attempt of attempts) {
    const up = await callComposio({
      apiKey: deps.composioApiKey,
      userId: deps.composioUserId,
      connectedAccountId: deps.driveAccountId,
      toolSlug: attempt.slug,
      toolArguments: attempt.args,
    });
    if (!up.ok) {
      convertErrors.push(`${attempt.slug}: ${up.error}`);
      continue;
    }
    const id: string = up.data?.id ?? up.data?.data?.id ?? up.data?.file_id ?? "";
    if (!id) {
      convertErrors.push(`${attempt.slug}: succeeded but returned no file id`);
      continue;
    }
    driveFileId = id;
    driveUrl = up.data?.webViewLink ?? up.data?.display_url ?? up.data?.data?.webViewLink ?? "";
    usedSlug = attempt.slug;
    break;
  }

  if (!driveFileId) {
    return { ok: false, stage: "convert", error: `no Drive upload tool worked — ${convertErrors.join(" | ")}` };
  }
  console.log(`[text_recovery] ${fileName}: converted in Drive via ${usedSlug}`);

  // ---- 3. Read the recovered text back --------------------------------
  const dl = await callComposio({
    apiKey: deps.composioApiKey,
    userId: deps.composioUserId,
    connectedAccountId: deps.driveAccountId,
    toolSlug: "GOOGLEDRIVE_DOWNLOAD_FILE",
    toolArguments: { fileId: driveFileId, mime_type: "text/plain" },
  });
  if (!dl.ok) {
    return { ok: false, stage: "read", error: `GOOGLEDRIVE_DOWNLOAD_FILE failed: ${dl.error}` };
  }
  const textUrl = signedLink(dl.data, "downloaded_file_content");
  if (!textUrl) {
    return { ok: false, stage: "read", error: "Drive returned no plain-text download link" };
  }

  let text = "";
  try {
    const r = await fetch(textUrl);
    if (!r.ok) {
      return { ok: false, stage: "read", error: `plain-text link returned HTTP ${r.status}` };
    }
    text = await r.text();
  } catch (e) {
    return {
      ok: false,
      stage: "read",
      error: `plain-text fetch threw: ${e instanceof Error ? e.message : String(e)}`,
    };
  }

  const trimmed = text.trim();
  if (trimmed.length < MIN_USEFUL_CHARS) {
    // The conversion ran but produced nothing usable — a blank page, a photo
    // of something that is not a document, or handwriting. Say so plainly
    // instead of handing a few stray characters to the identity step.
    return {
      ok: false,
      stage: "read",
      error: `text recognition recovered only ${trimmed.length} characters, too little to identify anyone`,
    };
  }

  return {
    ok: true,
    text: trimmed,
    driveFileId,
    driveUrl,
    charCount: trimmed.length,
  };
}
