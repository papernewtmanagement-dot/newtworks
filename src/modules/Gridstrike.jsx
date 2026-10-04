import { useCallback, useEffect, useRef, useState } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";

// =========================================================================
// Gridstrike.jsx — the print files for Gridstrike, the army-men game.
// It sits below the last sidebar line, so only owner, admin and the family
// login can open it (NewtworksApp.jsx enforces that for every link down there).
// The files live in the private storage bucket "gridstrike". Its read rule,
// gridstrike_family_read, lets in the same three logins and nobody else
// (migration gridstrike_print_files_bucket, 2026-10-04).
// manifest.json in the bucket lists the sections and files in order, with
// what is inside each file and how to print it. A new version is an upload
// plus a manifest edit: no code change, no deploy.
// A section can also name a storage folder ("folder": "3d"). Everything in
// that folder is listed under the section with a Download link, and owner
// and admin get an upload button there (zip, stl or pdf, 50 MB cap). Only
// the 3d/ folder takes uploads: gridstrike_admin_add_3d and
// gridstrike_admin_replace_3d (migration gridstrike_admin_upload_3d,
// 2026-10-04). The family login reads only. Nobody deletes from the page.
// "notes" in a section ({ "file name": "one line" }) describes folder files.
// Every link is signed and works for one hour; the page renews them every
// 45 minutes while it stays open. AGENCY_ID is imported by house rule.
// =========================================================================

const BUCKET = "gridstrike";
const LINK_SECONDS = 3600;
const RENEW_MS = 45 * 60 * 1000;
const MAX_BYTES = 50 * 1024 * 1024;   // the bucket's own size cap
const ADMIN_ROLES = ["owner", "admin"];
// The browser's own guess at a file type varies (Windows calls a zip
// application/x-zip-compressed), and the bucket only takes these types, so
// the page sets the type itself from the file name.
const UPLOAD_TYPES = { zip: "application/zip", stl: "model/stl", pdf: "application/pdf" };

const card = { background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 12, padding: 16, boxSizing: "border-box" };
const grid = { display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(280px, 1fr))", gap: 12 };
const niceDate = (iso) => {
  const d = new Date(`${iso}T12:00:00`);
  return Number.isFinite(d.getTime()) ? d.toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" }) : String(iso || "");
};
const niceStamp = (ts) => {
  const d = new Date(ts);
  return Number.isFinite(d.getTime()) ? d.toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" }) : "";
};
const niceSize = (n) => {
  const b = Number(n);
  if (!Number.isFinite(b) || b <= 0) return "";
  if (b >= 1024 * 1024) return `${(b / (1024 * 1024)).toFixed(1)} MB`;
  return `${Math.max(1, Math.round(b / 1024))} KB`;
};
// A folder name from the manifest: plain letters, numbers, dash or underscore only.
const folderOf = (section) => {
  const f = String(section?.folder || "").replace(/^\/+|\/+$/g, "");
  return /^[A-Za-z0-9_-]+$/.test(f) ? f : "";
};
// Storage keys get letters, numbers, dot, dash and underscore; anything else becomes _.
const safeName = (name) => {
  const s = String(name || "").replace(/[^A-Za-z0-9._-]+/g, "_").replace(/_+/g, "_").replace(/^[._]+/, "");
  return s.slice(-120) || "file";
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

  const folders = {};
  const names = [...new Set(manifest.sections.map(folderOf).filter(Boolean))];
  await Promise.all(names.map(async (folder) => {
    const { data, error: listError } = await store.list(folder, { limit: 200, sortBy: { column: "name", order: "asc" } });
    folders[folder] = listError ? null : (Array.isArray(data) ? data : [])
      .filter(x => x?.id && x?.name && !String(x.name).startsWith("."))
      .map(x => ({ path: `${folder}/${x.name}`, name: x.name, size: x?.metadata?.size, added: x?.updated_at || x?.created_at }));
  }));

  const paths = [
    ...manifest.sections.flatMap(s => (Array.isArray(s?.files) ? s.files : [])).map(f => f?.path).filter(Boolean),
    ...Object.values(folders).flatMap(list => (Array.isArray(list) ? list : []).map(x => x.path)),
  ];
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
  return { manifest, links, folders };
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

function FolderFile({ item, link, note }) {
  const isPdf = /\.pdf$/i.test(String(item?.name || ""));
  return (
    <div style={{ ...card, display: "flex", flexDirection: "column", gap: 8 }}>
      <div>
        <div style={{ fontSize: 15, fontWeight: 700, color: T.slate900, wordBreak: "break-word" }}>{item?.name}</div>
        <div style={{ fontSize: 12, color: T.slate500, marginTop: 2 }}>
          {[niceSize(item?.size), item?.added ? `added ${niceStamp(item.added)}` : null].filter(Boolean).join(" · ")}
        </div>
      </div>
      {note && <div style={{ fontSize: 13, color: T.slate700, lineHeight: 1.5 }}>{note}</div>}
      <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginTop: "auto" }}>
        {link?.save
          ? <a href={link.save} style={linkBtn("primary")}>Download</a>
          : <span style={{ fontSize: 12, color: T.slate500 }}>This file is not available right now. Reload the page.</span>}
        {isPdf && link?.open && <a href={link.open} target="_blank" rel="noopener noreferrer" style={linkBtn("soft")}>Open</a>}
      </div>
    </div>
  );
}

function Uploader({ folder, onDone }) {
  const inputRef = useRef(null);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState({ kind: "", text: "" });

  const onPick = async (e) => {
    const file = e?.target?.files?.[0];
    if (e?.target) e.target.value = "";   // so the same file can be picked again
    if (!file) return;
    const ext = String(file.name || "").split(".").pop().toLowerCase();
    const type = UPLOAD_TYPES[ext];
    if (!type) { setNote({ kind: "bad", text: "Only .zip, .stl or .pdf files can go here." }); return; }
    if (file.size > MAX_BYTES) {
      setNote({ kind: "bad", text: `That file is ${niceSize(file.size)}. The limit is 50 MB, so split it into smaller zips.` });
      return;
    }
    const name = safeName(file.name);
    setBusy(true);
    setNote({ kind: "", text: `Uploading ${name} (${niceSize(file.size)}). Big files can take a minute; keep this page open.` });
    let failure = "";
    try {
      const { error } = await supabase.storage.from(BUCKET)
        .upload(`${folder}/${name}`, new Blob([file], { type }), { upsert: true, contentType: type, cacheControl: "3600" });
      if (error) failure = error.message || "unknown error";
    } catch (err) {
      failure = err?.message || "the connection dropped";
    }
    setBusy(false);
    if (failure) { setNote({ kind: "bad", text: `The upload did not go through (${failure}). Try again, or ask Claude to check the Gridstrike files.` }); return; }
    setNote({ kind: "good", text: `${name} is saved.` });
    if (onDone) onDone();
  };

  const tone = note.kind === "bad" ? { background: T.redLt, color: T.slate800 }
    : note.kind === "good" ? { background: T.greenLt, color: T.slate800 }
    : { background: T.slate50, color: T.slate700 };
  return (
    <div style={{ ...card, background: T.slate50, marginTop: 12, display: "flex", flexDirection: "column", gap: 8 }}>
      <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900 }}>Add a 3D file (owner and admin only)</div>
      <div style={{ fontSize: 13, color: T.slate700, lineHeight: 1.5 }}>
        A zip, STL or PDF, up to 50 MB. A file with the same name replaces the old one.
      </div>
      <div>
        <input ref={inputRef} type="file" accept=".zip,.stl,.pdf" onChange={onPick} style={{ display: "none" }} />
        <button type="button" disabled={busy} onClick={() => inputRef.current?.click()}
          style={{ ...linkBtn("primary"), cursor: busy ? "default" : "pointer", opacity: busy ? 0.6 : 1 }}>
          {busy ? "Uploading…" : "Choose a file"}
        </button>
      </div>
      {note.text && <div style={{ ...tone, borderRadius: 8, padding: "8px 10px", fontSize: 13, lineHeight: 1.5 }}>{note.text}</div>}
    </div>
  );
}

export default function Gridstrike({ userRole }) {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";
  const [manifest, setManifest] = useState(null);
  const [links, setLinks] = useState({});
  const [folders, setFolders] = useState({});
  const [loading, setLoading] = useState(true);
  const [problem, setProblem] = useState("");
  const canUpload = ADMIN_ROLES.includes(userRole);

  const refresh = useCallback(async () => {
    let result = null;
    try { result = await loadFiles(); } catch { result = { error: "The files could not be reached." }; }
    if (result?.error) {
      setProblem(result.error);
    } else {
      setProblem("");
      setManifest(result.manifest);
      setLinks(result.links || {});
      setFolders(result.folders || {});
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
        const folder = folderOf(s);
        const listed = folder ? folders[folder] : [];
        const items = Array.isArray(listed) ? listed : [];
        const notes = s?.notes && typeof s.notes === "object" ? s.notes : {};
        return (
          <div key={s?.title || i} style={{ marginBottom: 22 }}>
            <div style={{ fontSize: 15, fontWeight: 700, color: T.slate900 }}>{s?.title}</div>
            {s?.blurb && <div style={{ fontSize: 13, color: T.slate500, margin: "2px 0 10px" }}>{s.blurb}</div>}
            {files.length + items.length > 0 ? (
              <div style={grid}>
                {files.map(f => <FileCard key={f?.path} file={f} link={links[f?.path]} />)}
                {items.map(x => <FolderFile key={x.path} item={x} link={links[x.path]} note={notes[x.name]} />)}
              </div>
            ) : (
              <div style={{ ...card, fontSize: 13, color: T.slate500 }}>Nothing here yet.</div>
            )}
            {folder && listed === null && (
              <div style={{ fontSize: 12, color: T.slate500, marginTop: 8 }}>The {folder} folder could not be read just now. Reload the page.</div>
            )}
            {folder === "3d" && canUpload && <Uploader folder={folder} onDone={refresh} />}
          </div>
        );
      })}
    </div>
  );
}
