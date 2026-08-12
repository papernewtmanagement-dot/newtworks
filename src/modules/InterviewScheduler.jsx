import { useState, useEffect, useCallback } from "react";
import { T } from "../lib/theme.js";

// NOTE: Mirrors CandidateAssessment.jsx's access model. This is a public
// route (/schedule/<token>) — no Supabase client, no session. The edge
// function hiring-interview-scheduler is the sole gateway; the token in the
// URL is the auth mechanism, verified server-side against
// hiring_candidates.interview_invite_token. Do not add a supabase import.

const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL || "";
const SUPABASE_ANON = import.meta.env.VITE_SUPABASE_ANON_KEY || "";
const ENDPOINT = `${SUPABASE_URL}/functions/v1/hiring-interview-scheduler`;

async function callScheduler(mode, extra = {}) {
  const headers = { "Content-Type": "application/json" };
  if (SUPABASE_ANON) {
    headers["Authorization"] = `Bearer ${SUPABASE_ANON}`;
    headers["apikey"] = SUPABASE_ANON;
  }
  try {
    const res = await fetch(ENDPOINT, {
      method: "POST",
      headers,
      body: JSON.stringify({ mode, ...extra }),
    });
    const data = await res.json().catch(() => ({ ok: false, error: "invalid_response" }));
    return { ok: res.ok, status: res.status, data };
  } catch (e) {
    return { ok: false, status: 0, data: { error: "network_error", detail: String(e?.message || e) } };
  }
}

function groupByDay(slots) {
  const groups = [];
  let lastDay = null;
  for (const s of slots) {
    const dayLabel = s.display.split(",").slice(0, 2).join(",").trim(); // "Monday, August 17"
    if (dayLabel !== lastDay) {
      groups.push({ day: dayLabel, items: [] });
      lastDay = dayLabel;
    }
    groups[groups.length - 1].items.push(s);
  }
  return groups;
}

function timeOnly(display) {
  // display format: "Monday, August 17, 2:00 PM" — take everything after the last comma
  const parts = display.split(",");
  return parts[parts.length - 1].trim();
}

export default function InterviewScheduler({ token }) {
  const [state, setState] = useState("loading"); // loading | error | pick | confirmed | expired
  const [payload, setPayload] = useState(null);
  const [picking, setPicking] = useState(null);
  const [errorMsg, setErrorMsg] = useState("");

  const load = useCallback(async () => {
    setState("loading");
    const { ok, data } = await callScheduler("get_offer", { token });
    if (!ok || !data?.ok) {
      setState("error");
      setErrorMsg(data?.error || "Something went wrong loading this link.");
      return;
    }
    setPayload(data);
    if (data.already_booked) setState("confirmed");
    else if (data.expired) setState("expired");
    else setState("pick");
  }, [token]);

  useEffect(() => { load(); }, [load]);

  const handlePick = async (slot) => {
    setPicking(slot.start);
    const { ok, data } = await callScheduler("claim_slot", { token, start: slot.start });
    if (ok && data?.ok) {
      setPayload((p) => ({ ...p, scheduled_start_display: data.scheduled_start_display, meet_url: data.meet_url }));
      setState("confirmed");
      setPicking(null);
      return;
    }
    if (data?.error === "slot_taken" || data?.error === "already_booked") {
      // Someone else took it (or a double-click) — refresh with the latest slots.
      setErrorMsg("That time was just taken — please pick another.");
      if (Array.isArray(data.slots)) {
        setPayload((p) => ({ ...p, slots: data.slots }));
      } else {
        await load();
      }
      setPicking(null);
      return;
    }
    setErrorMsg(data?.error || "Couldn't book that time — please try again.");
    setPicking(null);
  };

  const wrap = (children) => (
    <div style={{
      minHeight: "100vh", display: "flex", alignItems: "flex-start", justifyContent: "center",
      background: T?.slate50 || "#f8fafc", fontFamily: "'Poppins', 'Helvetica Neue', sans-serif",
      padding: "48px 16px",
    }}>
      <div style={{
        width: "100%", maxWidth: 480, background: "#fff", borderRadius: 16,
        boxShadow: "0 1px 3px rgba(0,0,0,0.08)", padding: 32,
      }}>
        {children}
      </div>
    </div>
  );

  if (state === "loading") {
    return wrap(<div style={{ color: T?.slate500 || "#64748b", fontSize: 14 }}>Loading…</div>);
  }

  if (state === "error") {
    return wrap(
      <>
        <h2 style={{ fontSize: 18, fontWeight: 600, marginBottom: 8 }}>This link isn't working</h2>
        <p style={{ fontSize: 14, color: T?.slate500 || "#64748b" }}>{errorMsg}. Please reach out to us directly and we'll get you scheduled.</p>
      </>
    );
  }

  if (state === "expired") {
    return wrap(
      <>
        <h2 style={{ fontSize: 18, fontWeight: 600, marginBottom: 8 }}>This scheduling link has expired</h2>
        <p style={{ fontSize: 14, color: T?.slate500 || "#64748b" }}>Please reach out to us directly and we'll get a new time set up.</p>
      </>
    );
  }

  if (state === "confirmed") {
    return wrap(
      <>
        <h2 style={{ fontSize: 20, fontWeight: 700, marginBottom: 12 }}>You're all set{payload?.first_name ? `, ${payload.first_name}` : ""}!</h2>
        <p style={{ fontSize: 15, marginBottom: 16 }}>
          <strong>{payload?.scheduled_start_display}</strong> (Central time)
        </p>
        {payload?.meet_url && (
          <a
            href={payload.meet_url}
            target="_blank"
            rel="noreferrer"
            style={{
              display: "inline-block", background: T?.blue600 || "#2563eb", color: "#fff",
              padding: "10px 18px", borderRadius: 8, textDecoration: "none", fontSize: 14, fontWeight: 600,
            }}
          >
            Join Google Meet link
          </a>
        )}
        <p style={{ fontSize: 13, color: T?.slate500 || "#64748b", marginTop: 20 }}>
          A confirmation email is on its way to you with these details. We look forward to speaking with you.
        </p>
      </>
    );
  }

  // state === "pick"
  const groups = groupByDay(payload?.slots || []);
  return wrap(
    <>
      <h2 style={{ fontSize: 20, fontWeight: 700, marginBottom: 4 }}>
        Hi {payload?.first_name || "there"} — pick a time
      </h2>
      <p style={{ fontSize: 14, color: T?.slate500 || "#64748b", marginBottom: 20 }}>
        About 35 minutes, over Google Meet. All times are Central.
      </p>
      {errorMsg && (
        <div style={{ background: "#fef2f2", color: "#b91c1c", fontSize: 13, padding: "8px 12px", borderRadius: 8, marginBottom: 16 }}>
          {errorMsg}
        </div>
      )}
      {groups.length === 0 && (
        <p style={{ fontSize: 14, color: T?.slate500 || "#64748b" }}>No open times right now — please reach out to us directly.</p>
      )}
      {groups.map((g) => (
        <div key={g.day} style={{ marginBottom: 18 }}>
          <div style={{ fontSize: 13, fontWeight: 600, color: T?.slate600 || "#475569", marginBottom: 8 }}>{g.day}</div>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
            {g.items.map((s) => (
              <button
                key={s.start}
                onClick={() => handlePick(s)}
                disabled={picking !== null}
                style={{
                  padding: "8px 14px", borderRadius: 8, border: `1px solid ${T?.slate200 || "#e2e8f0"}`,
                  background: picking === s.start ? (T?.slate100 || "#f1f5f9") : "#fff",
                  fontSize: 14, cursor: picking !== null ? "default" : "pointer",
                  opacity: picking !== null && picking !== s.start ? 0.5 : 1,
                }}
              >
                {picking === s.start ? "Booking…" : timeOnly(s.display)}
              </button>
            ))}
          </div>
        </div>
      ))}
    </>
  );
}
