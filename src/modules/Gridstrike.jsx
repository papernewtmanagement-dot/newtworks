import { useCallback, useEffect, useState } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";

// =========================================================================
// Gridstrike.jsx — the print files for Gridstrike, the army-men game.
// It sits below the last sidebar line, so only owner, admin and the family
// login can open it (NewtworksApp.jsx enforces that for every link down there).
// The files live in the private storage bucket "gridstrike". Its read rule,
// gridstrike_family_read, lets in the same three logins and nobody else, and
// only the service role can add or change files (migration
// gridstrike_print_files_bucket, 2026-10-04).
// manifest.json in the bucket lists the sections and files in order, with
// what is inside each file and how to print it. A new version is an upload
// plus a manifest edit: no code change, no deploy.
// Every link is signed and works for one hour; the page renews them every
// 45 minutes while it stays open. AGENCY_ID is imported by house rule.
// =========================================================================

const BUCKET = "gridstrike";
const LINK_SECONDS = 3600;
const RENEW_MS = 45 * 60 * 1000;

const card = { background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12, padding: 16, boxSizing: "border-box" };
const niceDate = (iso) => {
  const d = new Date(`${iso}T12:00:00`);
  return Number.isFinite(d.getTime()) ? d.toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" }) : String(iso || "");
};
const linkBtn = (kind) => ({
  display: "inline-block", boxSizing: "border-box", textDecoration: "none", whiteSpace: "nowrap",
  border: `1px solid ${kind === "primary" ? T.blue : T.slate200}`,
  background: kind === "primary" ? T.blue : T.white,
  color: kind === "primary" ? T.white : T.slate700,
  borderRadius: 8, padding: "8px 14px", fontSize: 13, fontWeight: 600, fontFamily: "inherit",
});

async function loadFiles() {
  const store = supabase.storage.from(BUCKET);
  const { data: blob, error } = await store.download("manifest.json");
  if (error || !blob) return { error: "The file list could not be opened." };
  let manifest = null;
  try { manifest = JSON.parse(await blob.text()); } catch { manifest = null; }
  if (!Array.isArray(manifest?.sections)) return { error: "The file list could not be read." };
  const paths = manifest.sections
    .flatMap(s => (Array.isArray(s?.files) ? s.files : []))
    .map(f => f?.path)
    .filter(Boolean);
  const links = {};
  if (paths.length) {
    const [open, save] = await Promise.all([
      store.createSignedUrls(paths, LINK_SECONDS),
      store.createSignedUrls(paths, LINK_SECONDS, { download: true }),
    ]);
    (Array.isArray(open?.data) ? open.data : []).forEach(x => {
      if (x?.path && x?.signedUrl) links[x.path] = { ...(links[x.path] || {}), open: x.signedUrl };
    });
    (Array.isArray(save?.data) ? save.data : []).forEach(x => {
      if (x?.path && x?.signedUrl) links[x.path] = { ...(links[x.path] || {}), save: x.signedUrl };
    });
  }
  return { manifest, links };
}

function FileCard({ file, link }) {
  const pages = Number.isFinite(Number(file?.pages)) ? Number(file.pages) : null;
  return (
    <div style={{ ...card, display: "flex", flexDirection: "column", gap: 10 }}>
      <div>
        <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>{file?.title || file?.path}</div>
        <div style={{ fontSize: 12, color: T.slate500, marginTop: 2 }}>
          {[file?.version, pages ? `${pages} ${pages === 1 ? "page" : "pages"}` : null].filter(Boolean).join(" · ")}
        </div>
      </div>
      {file?.inside && (
        <div style={{ fontSize: 13, color: T.slate700, lineHeight: 1.5 }}>
          <span style={{ fontWeight: 600, color: T.slate800 }}>What's inside: </span>{file.inside}
        </div>
      )}
      {file?.print && (
        <div style={{ fontSize: 13, color: T.slate700, lineHeight: 1.5 }}>
          <span style={{ fontWeight: 600, color: T.slate800 }}>How to print: </span>{file.print}
        </div>
      )}
      <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginTop: "auto" }}>
        {link?.open
          ? <a href={link.open} target="_blank" rel="noopener noreferrer" style={linkBtn("primary")}>Open to print</a>
          : <span style={{ fontSize: 12, color: T.slate500 }}>This file is not available right now. Reload the page.</span>}
        {link?.save && <a href={link.save} style={linkBtn("soft")}>Download</a>}
      </div>
    </div>
  );
}

export default function Gridstrike() {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";
  const [manifest, setManifest] = useState(null);
  const [links, setLinks] = useState({});
  const [loading, setLoading] = useState(true);
  const [problem, setProblem] = useState("");

  const refresh = useCallback(async () => {
    let result = null;
    try { result = await loadFiles(); } catch { result = { error: "The files could not be reached." }; }
    if (result?.error) {
      setProblem(result.error);
    } else {
      setProblem("");
      setManifest(result.manifest);
      setLinks(result.links || {});
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    refresh();
    const timer = setInterval(refresh, RENEW_MS);
    return () => clearInterval(timer);
  }, [refresh]);

  if (loading) return <div style={{ padding: _pad, color: T.slate500, fontSize: 13 }}>Loading…</div>;

  const sections = Array.isArray(manifest?.sections) ? manifest.sections : [];

  return (
    <div style={{ padding: _pad, maxWidth: 980, margin: "0 auto", boxSizing: "border-box" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", flexWrap: "wrap", gap: 8, marginBottom: 4 }}>
        <div style={{ fontSize: 20, fontWeight: 700, color: T.slate900 }}>Gridstrike</div>
        {manifest?.updated && <div style={{ fontSize: 12, color: T.slate500 }}>Files updated {niceDate(manifest.updated)}</div>}
      </div>
      <div style={{ fontSize: 13, color: T.slate500, marginBottom: 14 }}>
        Print files for the army-men game. Only the family login and admins can open this page and these files.
      </div>

      <div style={{ ...card, background: T.blueLt, borderColor: T.slate200, marginBottom: 18 }}>
        <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900, marginBottom: 6 }}>Before you print</div>
        <ul style={{ margin: 0, paddingLeft: 18, fontSize: 13, color: T.slate700, lineHeight: 1.6 }}>
          <li>Letter paper. Print at actual size (100%), not "Fit to page", so cards and tiles come out the right size.</li>
          <li>Rules pages go on plain paper. Cards, stand-ins and tiles go on card stock. Each file below says which pages are which.</li>
          <li>Open to print shows the file in a new tab with a print button. Download saves a copy.</li>
        </ul>
      </div>

      {problem && (
        <div style={{ ...card, background: T.redLt, borderColor: T.redLt, color: T.slate800, fontSize: 13, marginBottom: 18 }}>
          {problem} Reload the page. If it keeps happening, ask Claude to check the Gridstrike files.
        </div>
      )}

      {sections.map((s, i) => {
        const files = Array.isArray(s?.files) ? s.files : [];
        return (
          <div key={s?.title || i} style={{ marginBottom: 22 }}>
            <div style={{ fontSize: 15, fontWeight: 700, color: T.slate900 }}>{s?.title}</div>
            {s?.blurb && <div style={{ fontSize: 13, color: T.slate500, margin: "2px 0 10px" }}>{s.blurb}</div>}
            {files.length > 0 ? (
              <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(280px, 1fr))", gap: 12 }}>
                {files.map(f => <FileCard key={f?.path} file={f} link={links[f?.path]} />)}
              </div>
            ) : (
              <div style={{ ...card, fontSize: 13, color: T.slate500 }}>Nothing here yet.</div>
            )}
          </div>
        );
      })}
    </div>
  );
}
