// =========================================================================
// _shared/composio_stage.ts
// =========================================================================
// Put raw file bytes where Composio tools can reach them. Composio file
// arguments (GMAIL_SEND_EMAIL attachments, GOOGLEDRIVE_UPLOAD_FILE) take a
// { name, mimetype, s3key } pointer, never raw bytes, so a file this code
// built or downloaded itself has to be staged first.
//
// Flow, reachable with only the agency's composio_api_key:
//   1. POST /api/v3/files/upload/request -> { key, new_presigned_url, type }
//   2. PUT the raw bytes to new_presigned_url with a matching Content-Type
//   3. Pass key as the s3key
//
// Moved here 2026-10-09 from pfa-reconciliation-send so the CTS site pull
// (document-processor) uses the same function instead of a second copy.
// =========================================================================

import SparkMD5 from "npm:spark-md5@3.0.2";

export async function stageFileWithComposio(opts: {
  apiKey: string;
  fileName: string;
  mimeType: string;
  bytes: Uint8Array;
  toolSlug: string;
  toolkitSlug: string;
}): Promise<{ ok: boolean; s3key: string | null; error: string | null }> {
  let md5: string;
  try {
    const ab = opts.bytes.buffer.slice(
      opts.bytes.byteOffset,
      opts.bytes.byteOffset + opts.bytes.byteLength,
    );
    md5 = SparkMD5.ArrayBuffer.hash(ab);
  } catch (e) {
    return { ok: false, s3key: null, error: `md5 failed: ${e instanceof Error ? e.message : String(e)}` };
  }

  let presignRes: Response;
  try {
    presignRes = await fetch("https://backend.composio.dev/api/v3/files/upload/request", {
      method: "POST",
      headers: { "x-api-key": opts.apiKey, "Content-Type": "application/json" },
      body: JSON.stringify({
        filename: opts.fileName,
        mimetype: opts.mimeType,
        md5,
        tool_slug: opts.toolSlug,
        toolkit_slug: opts.toolkitSlug,
      }),
    });
  } catch (e) {
    return { ok: false, s3key: null, error: `presign threw: ${e instanceof Error ? e.message : String(e)}` };
  }
  const presignText = await presignRes.text();
  if (!presignRes.ok) {
    return { ok: false, s3key: null, error: `presign HTTP ${presignRes.status}: ${presignText.slice(0, 300)}` };
  }
  let presign: any;
  try { presign = JSON.parse(presignText); }
  catch { return { ok: false, s3key: null, error: `presign not JSON: ${presignText.slice(0, 200)}` }; }

  const uploadUrl: string | undefined = presign?.new_presigned_url ?? presign?.newPresignedUrl;
  const s3key: string | undefined = presign?.key;
  if (!uploadUrl || !s3key) {
    return { ok: false, s3key: null, error: `presign missing key/url: ${presignText.slice(0, 300)}` };
  }

  // type === "old" means Composio already holds this exact file (md5 match), so
  // the PUT is unnecessary. Re-uploading would be harmless, just wasteful.
  if (presign?.type !== "old") {
    let putRes: Response;
    try {
      putRes = await fetch(uploadUrl, {
        method: "PUT",
        headers: { "Content-Type": opts.mimeType },
        body: opts.bytes,
      });
    } catch (e) {
      return { ok: false, s3key: null, error: `upload PUT threw: ${e instanceof Error ? e.message : String(e)}` };
    }
    if (!putRes.ok) {
      const t = await putRes.text().catch(() => "");
      return { ok: false, s3key: null, error: `upload PUT HTTP ${putRes.status}: ${t.slice(0, 300)}` };
    }
  }

  return { ok: true, s3key, error: null };
}
