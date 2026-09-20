import { useState, useEffect, useCallback } from "react";
import { T } from "../lib/theme.js";

// NOTE: Mirrors InterviewScheduler.jsx's access model. This is a public
// route (/accept-offer/<token>) — no Supabase client, no session. The edge
// function hiring-offer-accept is the sole gateway; the token in the URL is
// the auth mechanism, verified server-side against
// hiring_candidates.offer_accept_token. Do not add a supabase import.
//
// The Social Security number is write-only from here. It is sent once, on
// accept, and nothing this page can call ever reads it back.

const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL || "";
const SUPABASE_ANON = import.meta.env.VITE_SUPABASE_ANON_KEY || "";
const ENDPOINT = `${SUPABASE_URL}/functions/v1/hiring-offer-accept`;

async function callAccept(mode, extra = {}) {
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

// Plain-English wording for everything the database can refuse. Keyed on the
// error the accept function returns, so there is one list rather than a
// message invented at each call site.
const PROBLEMS = {
  missing_signature: "Please type your full name to sign.",
  missing_name: "Please fill in your first and last name.",
  bad_email: "That email address does not look right. Please check it.",
  bad_phone: "Please enter a mobile number with all ten digits.",
  missing_date_of_birth: "Please enter your date of birth.",
  missing_address: "Please fill in your street, city, state and ZIP.",
  bad_ssn: "A Social Security number is nine digits. Please check what you entered.",
  missing_references: "Please fill in all three references.",
  reference_needs_name: "Every reference needs a name.",
  reference_needs_contact: "Every reference needs a phone number or an email address.",
  already_accepted: "This offer has already been accepted.",
  expired: "This link has expired.",
  not_found: "This link is not valid.",
  save_failed: "Something went wrong saving your details. Please try again.",
};

function formatSsn(raw) {
  const d = (raw || "").replace(/[^0-9]/g, "").slice(0, 9);
  if (d.length <= 3) return d;
  if (d.length <= 5) return `${d.slice(0, 3)}-${d.slice(3)}`;
  return `${d.slice(0, 3)}-${d.slice(3, 5)}-${d.slice(5)}`;
}

function prettyDate(iso) {
  if (!iso) return "";
  const d = new Date(`${iso}T12:00:00`);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" });
}

const EMPTY_REF = { contact_name: "", relationship: "", company: "", phone: "", email: "" };

export default function OfferAccept({ token }) {
  const [state, setState] = useState("loading"); // loading | form | done | expired | accepted | error
  const [offer, setOffer] = useState(null);
  const [saving, setSaving] = useState(false);
  const [problem, setProblem] = useState("");

  const [form, setForm] = useState({
    signed_name: "",
    first_name: "",
    last_name: "",
    nickname: "",
    email_personal: "",
    phone_personal: "",
    date_of_birth: "",
    address_line1: "",
    address_line2: "",
    city: "",
    state: "",
    zip_code: "",
    ssn: "",
  });
  const [refs, setRefs] = useState([{ ...EMPTY_REF }, { ...EMPTY_REF }, { ...EMPTY_REF }]);

  const load = useCallback(async () => {
    const { data } = await callAccept("get_offer", { token });
    if (!data?.ok) {
      setState(data?.error === "not_found" ? "error" : "error");
      setProblem(PROBLEMS[data?.error] || PROBLEMS.not_found);
      return;
    }
    if (data.accepted) { setOffer(data); setState("accepted"); return; }
    if (data.expired) { setOffer(data); setState("expired"); return; }
    setOffer(data);
    setForm((f) => ({
      ...f,
      first_name: data.prefill_first_name || "",
      last_name: data.prefill_last_name || "",
      nickname: data.prefill_nickname || "",
      email_personal: data.prefill_email || "",
      phone_personal: data.prefill_phone || "",
    }));
    const wanted = Math.max(1, data.references_wanted || 3);
    setRefs(Array.from({ length: wanted }, () => ({ ...EMPTY_REF })));
    setState("form");
  }, [token]);

  useEffect(() => { load(); }, [load]);

  const setField = (k, v) => setForm((f) => ({ ...f, [k]: v }));
  const setRef = (i, k, v) =>
    setRefs((rs) => rs.map((r, idx) => (idx === i ? { ...r, [k]: v } : r)));

  const submit = async () => {
    setSaving(true);
    setProblem("");
    const { data } = await callAccept("accept", {
      token,
      payload: { ...form, ssn: (form.ssn || "").replace(/[^0-9]/g, ""), references: refs },
    });
    setSaving(false);
    if (data?.ok) { setState("done"); return; }
    setProblem(PROBLEMS[data?.error] || PROBLEMS.save_failed);
  };

  // ---- styling ----------------------------------------------------------
  const wrap = (children) => (
    <div style={{
      minHeight: "100vh", display: "flex", alignItems: "flex-start", justifyContent: "center",
      background: T?.slate50 || "#f8fafc", fontFamily: "'Poppins', 'Helvetica Neue', sans-serif",
      padding: "48px 16px",
    }}>
      <div style={{
        width: "100%", maxWidth: 520, background: "#fff", borderRadius: 16,
        boxShadow: "0 1px 3px rgba(0,0,0,0.08)", padding: 32,
      }}>
        {children}
      </div>
    </div>
  );

  const label = { display: "block", fontSize: 12, fontWeight: 600, color: T?.slate600 || "#475569", marginBottom: 4 };
  const input = {
    width: "100%", boxSizing: "border-box", padding: "10px 12px", fontSize: 14,
    border: `1px solid ${T?.slate200 || "#e2e8f0"}`, borderRadius: 8, fontFamily: "inherit",
    background: "#fff", color: T?.slate900 || "#0f172a",
  };
  const row = { display: "flex", gap: 10, marginBottom: 12 };
  const h2 = { fontSize: 13, fontWeight: 700, color: T?.slate600 || "#475569", margin: "24px 0 12px", textTransform: "uppercase", letterSpacing: 0.4 };

  const field = (key, text, extra = {}) => (
    <div style={{ flex: 1, marginBottom: 12 }}>
      <label style={label}>{text}</label>
      <input
        style={input}
        value={form[key]}
        onChange={(e) => setField(key, e.target.value)}
        {...extra}
      />
    </div>
  );

  // ---- screens ----------------------------------------------------------
  if (state === "loading") {
    return wrap(<div style={{ color: T?.slate500 || "#64748b", fontSize: 14 }}>Loading…</div>);
  }

  if (state === "error" || state === "expired") {
    return wrap(
      <>
        <div style={{ fontSize: 20, fontWeight: 700, color: T?.slate900 || "#0f172a", marginBottom: 8 }}>
          {state === "expired" ? "This link has expired" : "This link is not valid"}
        </div>
        <div style={{ fontSize: 14, color: T?.slate600 || "#475569", lineHeight: 1.6 }}>
          Reply to the offer email and we will send you a fresh one straight away.
        </div>
      </>
    );
  }

  if (state === "accepted") {
    return wrap(
      <>
        <div style={{ fontSize: 20, fontWeight: 700, color: T?.slate900 || "#0f172a", marginBottom: 8 }}>
          You have already accepted
        </div>
        <div style={{ fontSize: 14, color: T?.slate600 || "#475569", lineHeight: 1.6 }}>
          We have everything we need. If something you entered was wrong, reply to the offer email and we will fix it.
        </div>
      </>
    );
  }

  if (state === "done") {
    return wrap(
      <>
        <div style={{ fontSize: 20, fontWeight: 700, color: T?.slate900 || "#0f172a", marginBottom: 8 }}>
          Thank you{offer?.first_name ? `, ${offer.first_name}` : ""} — that is everything
        </div>
        <div style={{ fontSize: 14, color: T?.slate600 || "#475569", lineHeight: 1.6 }}>
          <p style={{ marginTop: 0 }}>A confirmation is on its way to your inbox.</p>
          <p><b>One thing that helps:</b> let your three references know we will be calling them, so our call is not a surprise.</p>
          <p style={{ marginBottom: 0 }}>Once we have spoken to them we will be in touch about your start date.</p>
        </div>
      </>
    );
  }

  // ---- the form ---------------------------------------------------------
  return wrap(
    <>
      <div style={{ fontSize: 20, fontWeight: 700, color: T?.slate900 || "#0f172a", marginBottom: 6 }}>
        Accept your offer{offer?.job_title ? ` — ${offer.job_title}` : ""}
      </div>
      <div style={{ fontSize: 14, color: T?.slate600 || "#475569", lineHeight: 1.6, marginBottom: 4 }}>
        Hi {offer?.first_name}, we are glad you are joining us
        {offer?.start_date ? `, starting ${prettyDate(offer.start_date)}` : ""}.
      </div>
      <div style={{ fontSize: 13, color: T?.slate500 || "#64748b", lineHeight: 1.6, marginBottom: 4 }}>
        This takes about three minutes. Everything here is needed to get you set up for your first day.
      </div>
      {offer?.respond_by && (
        <div style={{ fontSize: 13, color: T?.slate500 || "#64748b", marginBottom: 4 }}>
          Please finish by {prettyDate(offer.respond_by)}.
        </div>
      )}

      <div style={h2}>About you</div>
      <div style={{ fontSize: 13, color: T?.slate600 || "#475569", lineHeight: 1.6, marginBottom: 14 }}>
        Check what we have and fix anything that is wrong. This is what we will set your
        record up with.
      </div>
      <div style={row}>
        <div style={{ flex: 1 }}>
          <label style={label}>First name</label>
          <input style={input} value={form.first_name}
                 onChange={(e) => setField("first_name", e.target.value)} />
        </div>
        <div style={{ flex: 1 }}>
          <label style={label}>Last name</label>
          <input style={input} value={form.last_name}
                 onChange={(e) => setField("last_name", e.target.value)} />
        </div>
      </div>
      {field("nickname", "What should we call you? (optional)", { placeholder: "Leave blank to use your first name" })}
      {field("email_personal", "Personal email", { inputMode: "email", type: "email" })}
      {field("phone_personal", "Mobile number", { inputMode: "tel", type: "tel" })}
      {field("date_of_birth", "Date of birth", { type: "date" })}

      <div style={h2}>Where you live</div>
      {field("address_line1", "Street address")}
      {field("address_line2", "Apartment or unit (optional)")}
      <div style={row}>
        <div style={{ flex: 2 }}>
          <label style={label}>City</label>
          <input style={input} value={form.city} onChange={(e) => setField("city", e.target.value)} />
        </div>
        <div style={{ flex: 1 }}>
          <label style={label}>State</label>
          <input style={input} value={form.state} maxLength={2}
                 onChange={(e) => setField("state", e.target.value.toUpperCase())} />
        </div>
        <div style={{ flex: 1 }}>
          <label style={label}>ZIP</label>
          <input style={input} value={form.zip_code} inputMode="numeric"
                 onChange={(e) => setField("zip_code", e.target.value)} />
        </div>
      </div>
      <div style={h2}>For payroll</div>
      <div style={{ marginBottom: 12 }}>
        <label style={label}>Social Security number</label>
        <input
          style={input}
          value={form.ssn}
          inputMode="numeric"
          autoComplete="off"
          placeholder="000-00-0000"
          onChange={(e) => setField("ssn", formatSsn(e.target.value))}
        />
        <div style={{ fontSize: 12, color: T?.slate500 || "#64748b", marginTop: 4 }}>
          This is for payroll only. It is stored separately from everything else and deleted once payroll is set up.
        </div>
      </div>

      <div style={h2}>Your references</div>
      <div style={{ fontSize: 13, color: T?.slate600 || "#475569", lineHeight: 1.6, marginBottom: 14 }}>
        Three people who can speak to your work history — former managers or supervisors are best.
        We will call them, so a phone number helps most. Please let them know to expect us.
      </div>
      {refs.map((r, i) => (
        <div key={i} style={{
          border: `1px solid ${T?.slate200 || "#e2e8f0"}`, borderRadius: 10,
          padding: 14, marginBottom: 12, background: T?.slate50 || "#f8fafc",
        }}>
          <div style={{ fontSize: 12, fontWeight: 700, color: T?.slate600 || "#475569", marginBottom: 10 }}>
            Reference {i + 1}
          </div>
          <div style={{ marginBottom: 10 }}>
            <label style={label}>Name</label>
            <input style={input} value={r.contact_name}
                   onChange={(e) => setRef(i, "contact_name", e.target.value)} />
          </div>
          <div style={{ display: "flex", gap: 10, marginBottom: 10 }}>
            <div style={{ flex: 1 }}>
              <label style={label}>Their role</label>
              <input style={input} value={r.relationship} placeholder="Manager"
                     onChange={(e) => setRef(i, "relationship", e.target.value)} />
            </div>
            <div style={{ flex: 1 }}>
              <label style={label}>Company</label>
              <input style={input} value={r.company}
                     onChange={(e) => setRef(i, "company", e.target.value)} />
            </div>
          </div>
          <div style={{ display: "flex", gap: 10 }}>
            <div style={{ flex: 1 }}>
              <label style={label}>Phone</label>
              <input style={input} value={r.phone} inputMode="tel"
                     onChange={(e) => setRef(i, "phone", e.target.value)} />
            </div>
            <div style={{ flex: 1 }}>
              <label style={label}>Email</label>
              <input style={input} value={r.email} inputMode="email"
                     onChange={(e) => setRef(i, "email", e.target.value)} />
            </div>
          </div>
        </div>
      ))}

      <div style={h2}>Sign</div>
      <div style={{ marginBottom: 14 }}>
        <label style={label}>Type your full name to accept this offer</label>
        <input style={input} value={form.signed_name}
               onChange={(e) => setField("signed_name", e.target.value)} />
      </div>

      {problem && (
        <div style={{ background: "#fef2f2", color: "#b91c1c", fontSize: 13, padding: "10px 12px", borderRadius: 8, marginBottom: 12 }}>
          {problem}
        </div>
      )}

      <button
        onClick={submit}
        disabled={saving}
        style={{
          width: "100%", padding: "12px 16px", fontSize: 15, fontWeight: 600,
          color: "#fff", background: saving ? (T?.slate400 || "#94a3b8") : (T?.blue || "#737A59"),
          border: "none", borderRadius: 8, cursor: saving ? "default" : "pointer",
          fontFamily: "inherit",
        }}
      >
        {saving ? "Sending…" : "Accept the offer"}
      </button>
    </>
  );
}
