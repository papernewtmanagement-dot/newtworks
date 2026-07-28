import { useEffect, useRef, useState } from "react";
import { supabase } from "./supabase.js";

// Session-level cache: one signed URL per storage path, valid ~1h from mint.
// Avoids re-signing on every remount/rerender across roster + settings surfaces.
const signedUrlCache = new Map(); // path -> { url, expiresAt }

async function getSignedPhotoUrl(path) {
  if (!path) return null;
  const now = Date.now();
  const cached = signedUrlCache.get(path);
  if (cached && cached.expiresAt > now + 60_000) return cached.url;
  try {
    const { data, error } = await supabase.storage
      .from("email_signatures")
      .createSignedUrl(path, 3600);
    if (error || !data?.signedUrl) return null;
    signedUrlCache.set(path, { url: data.signedUrl, expiresAt: now + 3600_000 });
    return data.signedUrl;
  } catch {
    return null;
  }
}

/**
 * Renders a photo square when photoStoragePath is set and the signed URL loads,
 * otherwise falls back to the initials string. Sizing/coloring is passed in so
 * callers keep control over their existing avatar box styling.
 */
export default function MemberAvatar({
  photoStoragePath = null,
  initials = "?",
  size = 48,
  borderRadius = 12,
  bg = "#E2E8F0",
  color = "#64748B",
  fontSize = 16,
  fontWeight = 700,
  style = null,
}) {
  const [url, setUrl] = useState(null);
  const [errored, setErrored] = useState(false);
  const mounted = useRef(true);

  useEffect(() => {
    mounted.current = true;
    setErrored(false);
    if (!photoStoragePath) { setUrl(null); return; }
    getSignedPhotoUrl(photoStoragePath).then(u => {
      if (mounted.current) setUrl(u);
    });
    return () => { mounted.current = false; };
  }, [photoStoragePath]);

  const boxStyle = {
    width: size,
    height: size,
    borderRadius,
    background: bg,
    color,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    fontSize,
    fontWeight,
    flexShrink: 0,
    overflow: "hidden",
    ...(style || {}),
  };

  const showPhoto = photoStoragePath && url && !errored;

  return (
    <div style={boxStyle}>
      {showPhoto ? (
        <img
          src={url}
          alt=""
          onError={() => setErrored(true)}
          style={{ width: "100%", height: "100%", objectFit: "cover", display: "block" }}
        />
      ) : (
        initials
      )}
    </div>
  );
}
