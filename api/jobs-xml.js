// api/jobs-xml — Vercel Edge Function.
//
// WHY THIS LIVES ON VERCEL AND NOT SUPABASE:
// Supabase Edge Functions do not control their own response content type for
// document-like responses. The jobs-xml-feed function sets
// "application/xml; charset=utf-8", and Supabase's runtime rewrites it to
// "text/plain" and attaches a locked-down security header
// ("default-src 'none'; sandbox"). Verified live 2026-08-13. This is the same
// documented platform restriction that forced the careers page onto Vercel.
//
// The consequence was that any job board fetching /jobs.xml was told the
// document is plain text rather than XML, and anyone opening the feed in a
// browser to review it saw raw source instead of a parsed feed.
//
// This file leaves every piece of feed-building logic where it already lives,
// in the Supabase function, and corrects only the response headers on the way
// out. It holds no database credentials of its own.
//
// ROUTING: vercel.json rewrites /jobs.xml to this file.

const FEED_ORIGIN = `${process.env.VITE_SUPABASE_URL}/functions/v1/jobs-xml-feed`;

export const config = { runtime: "edge" };

export default async function handler(req) {
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response("Method not allowed", { status: 405 });
  }

  try {
    const upstream = await fetch(FEED_ORIGIN, { method: "GET" });

    if (!upstream.ok) {
      console.error("jobs-xml upstream status", upstream.status);
      return new Response("Feed unavailable", { status: 502 });
    }

    const xml = await upstream.text();

    return new Response(req.method === "HEAD" ? null : xml, {
      status: 200,
      headers: {
        "content-type": "application/xml; charset=utf-8",
        // Mirrors the cache window the feed function already sets. Indeed and
        // ZipRecruiter both crawl at roughly hourly cadence.
        "cache-control": "public, max-age=900, s-maxage=900",
        "x-content-type-options": "nosniff",
      },
    });
  } catch (e) {
    console.error("jobs-xml proxy error", e);
    return new Response("Feed unavailable", { status: 502 });
  }
}
