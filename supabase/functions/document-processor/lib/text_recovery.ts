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
//   Google Drive reads the page images of a file when the file is brought in
//   AS a Google Doc. That costs nothing beyond the Drive account already
//   connected, needs no new vendor and no charge per file, and the recovered
//   text feeds the existing identity step unchanged.
//
//   An earlier plan assumed these files were already sitting in Drive and
//   could simply be converted in place. They are not: checked live on
//   2026-08-04, none of the 143 forwarded resumes ever got a Drive copy,
//   because the upload step had been failing quietly for weeks. So this brings
//   the file in from Gmail rather than converting something already there.
//
// THE CHAIN:
//   1. Ask Gmail for the attachment. It answers with a temporary signed link,
//      good for an hour, not with the bytes.
//   2. Get that link into Drive as a Google Doc. Two doors are tried, in order
//      of how well they work — see the note on the conversion step below.
//   3. Read the new document back as plain text. Two doors here as well.
//
// The converted document is deliberately KEPT, not deleted. It becomes the
// Drive copy these resumes have always been missing, and the caller writes its
// id onto the documents row.
//
// EVERY FAILURE NAMES ITS STAGE AND ITS DOOR. The three stages have three
// completely different fixes, and the log cannot be read after the fact, so
// the detail has to travel back in the returned value.
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
      /** Which conversion door worked, and which read door. For the record. */
      via: string;
    }
  | { ok: false; error: string; stage: "gmail" | "convert" | "read" };

/** The Drive type that makes Drive read the page images of a scan. */
const DRIVE_DOC_MIME = "application/vnd.google-apps.document";

/** Shortest recovered text we will treat as a real result. */
const MIN_USEFUL_CHARS = 40;

function stripExtension(fileName: string): string {
  return fileName.replace(/\.[A-Za-z0-9]{1,6}$/, "").trim() || fileName;
}

/**
 * Pull the storage key out of a Composio download link. The link is a signed
 * URL whose path IS the key, e.g. ".../486473/gmail/GMAIL_GET_ATTACHMENT/
 * response/abc123?X-Amz-...". The plain upload tool wants exactly that path,
 * not the whole link and not the bytes.
 */
function storageKeyFromUrl(url: string): string | null {
  try {
    const path = new URL(url).pathname.replace(/^\/+/, "");
    return path.length > 0 ? decodeURIComponent(path) : null;
  } catch {
    return null;
  }
}

/** Best guess at the original file's type, from its extension. */
function guessSourceMime(fileName: string): string {
  const ext = fileName.toLowerCase().match(/\.([a-z0-9]{1,6})$/)?.[1] ?? "";
  if (ext === "jpg" || ext === "jpeg") return "image/jpeg";
  if (ext === "png") return "image/png";
  if (ext === "gif") return "image/gif";
  if (ext === "tif" || ext === "tiff") return "image/tiff";
  if (ext === "webp") return "image/webp";
  return "application/pdf";
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

function firstId(data: any): string {
  return data?.id ?? data?.data?.id ?? data?.file_id ?? data?.data?.file_id ?? "";
}

/**
 * Recover text from one scanned file.
 */
export async function recoverTextFromScannedFile(opts: {
  deps: TextRecoveryDeps;
  messageId: string;
  attachmentId: string;
  fileName: string;
}): Promise<TextRecoveryResult> {
  const { deps, messageId, attachmentId, fileName } = opts;
  const tried: string[] = [];

  if (!deps.driveAccountId) {
    return { ok: false, stage: "convert", error: "no Drive account connected, cannot read the page images" };
  }
  if (!messageId || !attachmentId) {
    return {
      ok: false,
      stage: "gmail",
      error: "no Gmail message id or attachment id on this file, so the original cannot be fetched again",
    };
  }

  const drive = async (slug: string, toolArguments: Record<string, any>) => {
    tried.push(slug);
    return await callComposio({
      apiKey: deps.composioApiKey,
      userId: deps.composioUserId,
      connectedAccountId: deps.driveAccountId as string,
      toolSlug: slug,
      toolArguments,
    });
  };

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

  // ---- 2. Get it into Drive as a Google Doc ----------------------------
  // TWO DOORS, tried in this order. Both were checked live on 2026-08-04.
  //
  // Door 1 hands Drive the link and asks for a Google Doc in a single call.
  // This is the mechanism the tool itself documents for page-image files, and
  // it is the one that works when the same chain is run by hand. It is tried
  // first because it is one call instead of two and needs no storage key.
  //
  // Door 2 is the two-call route: upload a faithful copy of the original, then
  // copy that copy as a Google Doc. Kept as the fallback because the plain
  // upload is the one Drive tool this function is definitely able to reach.
  //
  // A door that answers "Tool ... not found" is not broken and not misused —
  // it means this function's Composio key cannot see that tool at all, even
  // though an interactive session can. Do not spend a deploy cycle re-testing
  // it. Whichever door works is reported back in `via`.
  let docId = "";
  let docUrl = "";
  let via = "";

  const fromUrl = await drive("GOOGLEDRIVE_UPLOAD_FROM_URL", {
    source_url: sourceUrl,
    name: stripExtension(fileName),
    mime_type: DRIVE_DOC_MIME,
    ...(deps.driveParentFolderId ? { parent_folder_id: deps.driveParentFolderId } : {}),
  });
  if (fromUrl.ok && firstId(fromUrl.data)) {
    docId = firstId(fromUrl.data);
    docUrl = fromUrl.data?.webViewLink ?? fromUrl.data?.display_url ?? "";
    via = "upload_from_url";
  }

  let convertError = fromUrl.ok ? "returned no document id" : String(fromUrl.error);

  if (!docId) {
    const s3Key = storageKeyFromUrl(sourceUrl);
    if (!s3Key) {
      return {
        ok: false,
        stage: "convert",
        error: `${convertError}; and no storage key could be read out of the Gmail link for the fallback route`,
      };
    }

    const up = await drive("GOOGLEDRIVE_UPLOAD_FILE", {
      file_to_upload: {
        name: fileName,
        mimetype: guessSourceMime(fileName),
        s3key: s3Key,
      },
      ...(deps.driveParentFolderId ? { folder_to_upload_to: deps.driveParentFolderId } : {}),
    });
    if (!up.ok || !firstId(up.data)) {
      return {
        ok: false,
        stage: "convert",
        error: `both conversion routes failed. upload-from-link: ${convertError}. plain upload: ${up.ok ? "returned no file id" : up.error}`,
      };
    }
    const originalId = firstId(up.data);

    // Copy it AS a Google Doc. Naming the Doc type as the target is what makes
    // Drive read the page images; the language hint improves that reading. The
    // Doc type cannot be set on the upload itself — Drive rejects it outright
    // as an upload type, checked live 2026-08-04.
    const conv = await drive("GOOGLEDRIVE_COPY_FILE_ADVANCED", {
      fileId: originalId,
      name: `${stripExtension(fileName)} (text)`,
      mimeType: DRIVE_DOC_MIME,
      ocrLanguage: "en",
      ...(deps.driveParentFolderId ? { parents: [deps.driveParentFolderId] } : {}),
    });
    if (!conv.ok || !firstId(conv.data)) {
      return {
        ok: false,
        stage: "convert",
        error: `both conversion routes failed. upload-from-link: ${convertError}. copy-as-document: ${conv.ok ? "returned no document id" : conv.error}. The original file did upload to Drive as ${originalId}, so the Drive copy is not lost. Tried: ${tried.join(", ")}`,
      };
    }
    docId = firstId(conv.data);
    docUrl = conv.data?.webViewLink ?? conv.data?.display_url ?? "";
    via = "upload_then_copy";
  }

  if (!docUrl) docUrl = `https://docs.google.com/document/d/${docId}/edit`;

  // ---- 3. Read the recovered text back --------------------------------
  // Two doors again. The first exports a Google Doc to plain text directly.
  // The second is the dedicated export tool, same idea, different slug — kept
  // because which of the two a given key can see is not predictable.
  let textUrl: string | null = null;
  let readError = "";

  const dl = await drive("GOOGLEDRIVE_DOWNLOAD_FILE", { fileId: docId, mime_type: "text/plain" });
  if (dl.ok) {
    textUrl = signedLink(dl.data, "downloaded_file_content");
    if (!textUrl) readError = "GOOGLEDRIVE_DOWNLOAD_FILE returned no plain-text link";
  } else {
    readError = `GOOGLEDRIVE_DOWNLOAD_FILE failed: ${dl.error}`;
  }

  if (!textUrl) {
    const ex = await drive("GOOGLEDRIVE_EXPORT_GOOGLE_WORKSPACE_FILE", {
      fileId: docId,
      mimeType: "text/plain",
    });
    if (ex.ok) {
      textUrl = signedLink(ex.data, "downloaded_file_content") ?? signedLink(ex.data, "file");
      if (textUrl) via = `${via}+export`;
    }
    if (!textUrl) {
      return {
        ok: false,
        stage: "read",
        error: `${readError}; export fallback also failed: ${ex.ok ? "no link returned" : ex.error}. The converted document exists as ${docId}, so the text is recoverable by hand. Tried: ${tried.join(", ")}`,
      };
    }
  }

  let text = "";
  try {
    const r = await fetch(textUrl);
    if (!r.ok) {
      return { ok: false, stage: "read", error: `plain-text link returned HTTP ${r.status}; document is ${docId}` };
    }
    text = await r.text();
  } catch (e) {
    return {
      ok: false,
      stage: "read",
      error: `plain-text fetch threw: ${e instanceof Error ? e.message : String(e)}; document is ${docId}`,
    };
  }

  // Drive puts a byte-order mark at the front of an exported text file. Left in
  // place it becomes the first character of the candidate's first name.
  const trimmed = text.replace(/^\uFEFF/, "").trim();
  if (trimmed.length < MIN_USEFUL_CHARS) {
    // The conversion ran but produced nothing usable — a blank page, a photo
    // of something that is not a document, or handwriting. Say so plainly
    // instead of handing a few stray characters to the identity step.
    return {
      ok: false,
      stage: "read",
      error: `reading the page images recovered only ${trimmed.length} characters, too little to identify anyone; document is ${docId}`,
    };
  }

  return {
    ok: true,
    text: trimmed,
    driveFileId: docId,
    driveUrl: docUrl,
    charCount: trimmed.length,
    via,
  };
}
