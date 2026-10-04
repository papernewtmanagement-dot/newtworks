import { useState, useEffect, useCallback } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import { mdToHtml } from "../lib/markdown.js";
import { useTabParam } from "../lib/routing.jsx";

// =========================================================================
// TeamForms.jsx
// =========================================================================
// The five hiring forms. Every one is a form on this site — nothing here is
// a file upload, including the I-9.
//
// Two ways in:
//   <TeamForms teamId={me} />                  Development > Forms. Your own.
//   <TeamForms teamId={x} isAdmin />           Team record. Anyone's, plus the
//                                              button that destroys the Social
//                                              Security number and bank details.
//
// The permission split is enforced in the database, not here. Hiding a button
// is not security — the policies on team_form_secure are.
// =========================================================================

// Exported so the onboarding template can link each form without keeping a
// second list of them.
export const FORMS = [
  { id: "login_packet", label: "Login Packet",
    blurb: "Your State Farm sign-in details and first-day setup steps." },
  { id: "combined_onboarding", label: "Onboarding",
    blurb: "Your details, your story, and payroll setup." },
  { id: "w4", label: "W-4",
    blurb: "Federal tax withholding for your paycheck." },
  { id: "non_compete", label: "Non-compete",
    blurb: "Read it and agree. A copy is emailed to you." },
  { id: "i9", label: "I-9",
    blurb: "Work authorization. Your documents are checked in person." },
  { id: "handbook_ack", label: "Handbook",
    blurb: "Read the current handbook and confirm." },
];

const STATE_STYLE = {
  complete:          { bg: T.greenLt, fg: "#1B5E36", label: "Done" },
  action_needed:     { bg: T.amberLt, fg: "#7A5B08", label: "Action needed" },
  awaiting_employer: { bg: T.blueLt,  fg: T.slate700, label: "Waiting on the agency" },
  waived:            { bg: T.slate100, fg: T.slate600, label: "Waived" },
};

// ─── small shared pieces ────────────────────────────────────────────────

function Pill({ state }) {
  const s = STATE_STYLE[state] || STATE_STYLE.action_needed;
  return (
    <span style={{
      background: s.bg, color: s.fg, fontSize: 11, fontWeight: 700,
      padding: "3px 9px", borderRadius: 999, whiteSpace: "nowrap",
    }}>{s.label}</span>
  );
}

const inputBase = {
  width: "100%", boxSizing: "border-box", padding: "9px 11px",
  border: `1px solid ${T.slate200}`, borderRadius: 8, fontSize: 14,
  color: T.slate900, background: T.white, fontFamily: "inherit",
};

function Field({ label, children, hint, wide }) {
  return (
    <label style={{ display: "block", minWidth: 0, gridColumn: wide ? "1 / -1" : "auto" }}>
      <div style={{ fontSize: 12, fontWeight: 600, color: T.slate600, marginBottom: 5 }}>
        {label}
      </div>
      {children}
      {hint && <div style={{ fontSize: 11, color: T.slate500, marginTop: 4 }}>{hint}</div>}
    </label>
  );
}

function Text({ value, onChange, placeholder, type = "text" }) {
  return (
    <input type={type} value={value || ""} placeholder={placeholder}
      onChange={e => onChange(e.target.value)} style={inputBase} />
  );
}

function Area({ value, onChange, rows = 3, placeholder }) {
  return (
    <textarea value={value || ""} rows={rows} placeholder={placeholder}
      onChange={e => onChange(e.target.value)}
      style={{ ...inputBase, resize: "vertical", lineHeight: 1.5 }} />
  );
}

function Grid({ children, min = 240 }) {
  return (
    <div style={{
      display: "grid", gap: 14, marginTop: 4,
      gridTemplateColumns: `repeat(auto-fit, minmax(${min}px, 1fr))`,
    }}>{children}</div>
  );
}

export function Section({ title, note, children }) {
  return (
    <div style={{ marginTop: 26 }}>
      <div style={{ fontSize: 15, fontWeight: 700, color: T.slate900 }}>{title}</div>
      {note && <div style={{ fontSize: 12.5, color: T.slate500, marginTop: 4, lineHeight: 1.5 }}>{note}</div>}
      <div style={{ marginTop: 12 }}>{children}</div>
    </div>
  );
}

function Button({ children, onClick, tone = "primary", disabled, wide }) {
  const tones = {
    primary: { background: T.blue, color: T.white, border: `1px solid ${T.blue}` },
    quiet:   { background: T.white, color: T.slate700, border: `1px solid ${T.slate200}` },
    danger:  { background: T.white, color: T.red, border: `1px solid ${T.red}` },
  };
  return (
    <button onClick={onClick} disabled={disabled} style={{
      ...tones[tone], padding: "10px 18px", borderRadius: 8, fontSize: 14,
      fontWeight: 600, cursor: disabled ? "not-allowed" : "pointer",
      opacity: disabled ? 0.5 : 1, boxSizing: "border-box",
      width: wide ? "100%" : "auto", fontFamily: "inherit",
    }}>{children}</button>
  );
}

// Section and Check are also used by the orientation pop-up, so the two look
// the same.
export function Check({ checked, onChange, children, disabled = false }) {
  return (
    <label style={{
      display: "flex", gap: 10, alignItems: "flex-start", cursor: disabled ? "not-allowed" : "pointer",
      padding: "12px 14px", border: `1px solid ${checked ? T.blue : T.slate200}`,
      background: checked ? T.blueLt : T.white, borderRadius: 8, boxSizing: "border-box",
      opacity: disabled ? 0.6 : 1,
    }}>
      <input type="checkbox" checked={!!checked} disabled={disabled} onChange={e => onChange(e.target.checked)}
        style={{ marginTop: 2, width: 16, height: 16, flexShrink: 0, accentColor: T.blue }} />
      <span style={{ fontSize: 13.5, color: T.slate800, lineHeight: 1.5 }}>{children}</span>
    </label>
  );
}

// ─── the combined onboarding form ───────────────────────────────────────
// Bio, the why statement, and the payroll half. Peter explains the why idea
// at orientation and this is filled in afterwards.

// key = what is saved (kept so earlier answers still line up); label = what is shown
const RANKABLE = [
  { key: "Words of Affirmation", label: "Encouragement" },
  { key: "Paid Time Off", label: "Paid Time Off" },
  { key: "Awards", label: "Awards" },
  { key: "Bonuses", label: "Bonuses" },
];
const EMPTY_BANK = { bank_name: "", routing_number: "", account_number: "", account_type: "checking", percent: "" };

function CombinedForm({ data, setData, secure, setSecure }) {
  const set = (k) => (v) => setData({ ...data, [k]: v });
  const banks = secure.banks && secure.banks.length ? secure.banks : [{ ...EMPTY_BANK }];
  const setBank = (i, k, v) => {
    const next = banks.map((b, j) => (j === i ? { ...b, [k]: v } : b));
    setSecure({ ...secure, banks: next });
  };

  return (
    <div>
      <Section title="About you">
        <Grid>
          <Field label="Where were you born and raised?">
            <Text value={data.born_raised} onChange={set("born_raised")} />
          </Field>
          <Field label="When did you move to San Antonio, and why?">
            <Text value={data.moved_here} onChange={set("moved_here")} />
          </Field>
          <Field label="What are you licensed in?">
            <Text value={data.licensed_in} onChange={set("licensed_in")} />
          </Field>
          <Field label="When did you start in risk and wealth management?">
            <Text value={data.started_industry} onChange={set("started_industry")} />
          </Field>
          <Field wide label="What do you bring to this career that will make the biggest impact on customers' lives?">
            <Area value={data.biggest_impact} onChange={set("biggest_impact")} rows={3} />
          </Field>
        </Grid>
      </Section>

      <Section title="Your why"
        note="The one Peter walked through at orientation. Write it in your own words.">
        <Area value={data.why_statement} onChange={set("why_statement")} rows={5} />
      </Section>

      <Section title="What motivates you" note="Rank these from 1 down to 4.">
        <Grid min={200}>
          {RANKABLE.map(({ key: r, label }) => (
            <Field key={r} label={label}>
              <select value={(data.ranking || {})[r] || ""}
                onChange={e => setData({ ...data, ranking: { ...(data.ranking || {}), [r]: e.target.value } })}
                style={inputBase}>
                <option value="">—</option>
                {[1, 2, 3, 4].map(n => <option key={n} value={n}>{n}</option>)}
              </select>
            </Field>
          ))}
        </Grid>
      </Section>

      <Section title="The small things" note="So we get the details right.">
        <Grid min={200}>
          <Field label="Favorite gift card">
            <Text value={data.gift_card} onChange={set("gift_card")} />
          </Field>
          <Field label="What do you do for fun or to relax?">
            <Text value={data.fun_relax} onChange={set("fun_relax")} />
          </Field>
          <Field label="Favorite restaurant"><Text value={data.fav_restaurant} onChange={set("fav_restaurant")} /></Field>
          <Field label="Favorite lunch"><Text value={data.fav_lunch} onChange={set("fav_lunch")} /></Field>
          <Field label="Favorite snack"><Text value={data.fav_snack} onChange={set("fav_snack")} /></Field>
          <Field label="Favorite beverage"><Text value={data.fav_beverage} onChange={set("fav_beverage")} /></Field>
          <Field label="Shirt size"><Text value={data.shirt_size} onChange={set("shirt_size")} /></Field>
          <Field label="Shoe size"><Text value={data.shoe_size} onChange={set("shoe_size")} /></Field>
          <Field label="Favorite color"><Text value={data.fav_color} onChange={set("fav_color")} /></Field>
        </Grid>
      </Section>

      <Section title="Top five places you want to travel">
        <Grid min={180}>
          {[0, 1, 2, 3, 4].map(i => (
            <Field key={i} label={`${i + 1}.`}>
              <Text value={(data.travel || [])[i]}
                onChange={v => {
                  const next = [...(data.travel || ["", "", "", "", ""])];
                  next[i] = v;
                  setData({ ...data, travel: next });
                }} />
            </Field>
          ))}
        </Grid>
      </Section>

      <Section title="Payroll"
        note="This goes straight into SurePayroll and is then destroyed. It is never shown back to you, and nobody but Peter and a manager can read it.">
        {banks.map((b, i) => (
          <div key={i} style={{
            marginTop: 16, padding: 14, border: `1px solid ${T.slate200}`,
            borderRadius: 10, background: T.slate50, boxSizing: "border-box",
          }}>
            <div style={{ fontSize: 12, fontWeight: 700, color: T.slate600, marginBottom: 10 }}>
              {i === 0 ? "Bank" : `Bank ${i + 1}`}
            </div>
            <Grid min={190}>
              <Field label="Bank name"><Text value={b.bank_name} onChange={v => setBank(i, "bank_name", v)} /></Field>
              <Field label="Routing number"><Text value={b.routing_number} onChange={v => setBank(i, "routing_number", v)} /></Field>
              <Field label="Account number"><Text value={b.account_number} onChange={v => setBank(i, "account_number", v)} /></Field>
              <Field label="Checking or savings">
                <select value={b.account_type || "checking"} onChange={e => setBank(i, "account_type", e.target.value)} style={inputBase}>
                  <option value="checking">Checking</option>
                  <option value="savings">Savings</option>
                </select>
              </Field>
              <Field label="Percent of pay" hint="Leave blank if this is the only account.">
                <Text value={b.percent} onChange={v => setBank(i, "percent", v)} placeholder="100" />
              </Field>
            </Grid>
          </div>
        ))}

        {banks.length < 3 && (
          <div style={{ marginTop: 12 }}>
            <Button tone="quiet" onClick={() => setSecure({ ...secure, banks: [...banks, { ...EMPTY_BANK }] })}>
              Add another bank
            </Button>
          </div>
        )}
      </Section>
    </div>
  );
}

// ─── non-compete ────────────────────────────────────────────────────────
// Peter wrote it. He does not sign it. The team member reads it and agrees.

function NonCompeteForm({ doc, data, setData }) {
  if (!doc) return <div style={{ color: T.slate500, fontSize: 14 }}>No agreement has been published yet.</div>;
  return (
    <div>
      <div style={{
        marginTop: 18, padding: "18px 20px", border: `1px solid ${T.slate200}`,
        borderRadius: 10, background: T.white, maxHeight: 460, overflowY: "auto",
        fontSize: 13.5, lineHeight: 1.65, color: T.slate800, boxSizing: "border-box",
      }} dangerouslySetInnerHTML={{ __html: mdToHtml(doc.body || "") }} />
      <div style={{ marginTop: 16 }}>
        <Check checked={data.agreed} onChange={v => setData({ ...data, agreed: v })}>
          I have read and understand this Agreement, I agree to comply with all of its
          terms, and I have received a copy of it.
        </Check>
      </div>
    </div>
  );
}

// ─── handbook acknowledgment ────────────────────────────────────────────

function HandbookForm({ doc, data, setData }) {
  return (
    <div>
      <div style={{
        marginTop: 18, padding: "16px 18px", border: `1px solid ${T.slate200}`,
        borderRadius: 10, background: T.slate50, boxSizing: "border-box",
      }}>
        <div style={{ fontSize: 14, fontWeight: 600, color: T.slate900 }}>
          {doc ? doc.title : "Team Member Handbook"}
          {doc && <span style={{ color: T.slate500, fontWeight: 500 }}> — version {doc.version}</span>}
        </div>
        <div style={{ fontSize: 12.5, color: T.slate500, marginTop: 6, lineHeight: 1.5 }}>
          Read it in full before you confirm. When a new version is published this
          comes back around.
        </div>
        <div style={{ marginTop: 12 }}>
          <a href="/handbook" style={{
            fontSize: 13.5, fontWeight: 600, color: T.blue, textDecoration: "none",
          }}>Open the handbook</a>
        </div>
      </div>
      <div style={{ marginTop: 16 }}>
        <Check checked={data.agreed} onChange={v => setData({ ...data, agreed: v })}>
          I have read the current handbook and I understand what it asks of me.
        </Check>
      </div>
    </div>
  );
}

// ─── I-9 ────────────────────────────────────────────────────────────────
// Two parts. The employee fills in the first. Someone at the agency fills in
// the second after looking at the original documents in person.

const CITIZENSHIP = [
  { v: "citizen", label: "A citizen of the United States" },
  { v: "national", label: "A noncitizen national of the United States" },
  { v: "permanent_resident", label: "A lawful permanent resident" },
  { v: "authorized_alien", label: "A noncitizen authorized to work" },
];

function I9EmployeeSection({ data, setData, locked }) {
  const set = (k) => (v) => setData({ ...data, [k]: v });
  const dis = locked ? { pointerEvents: "none", opacity: 0.65 } : null;
  return (
    <div style={dis}>
      <Section title="Section 1 — you">
        <Grid min={200}>
          <Field label="Last name (family name)"><Text value={data.last_name} onChange={set("last_name")} /></Field>
          <Field label="First name (given name)"><Text value={data.first_name} onChange={set("first_name")} /></Field>
          <Field label="Middle initial"><Text value={data.middle_initial} onChange={set("middle_initial")} /></Field>
          <Field label="Other last names used" hint="If none, write None."><Text value={data.other_names} onChange={set("other_names")} /></Field>
          <Field label="Street address"><Text value={data.address} onChange={set("address")} /></Field>
          <Field label="Apartment"><Text value={data.apt} onChange={set("apt")} /></Field>
          <Field label="City"><Text value={data.city} onChange={set("city")} /></Field>
          <Field label="State"><Text value={data.state} onChange={set("state")} /></Field>
          <Field label="ZIP code"><Text value={data.zip} onChange={set("zip")} /></Field>
          <Field label="Date of birth"><Text type="date" value={data.dob} onChange={set("dob")} /></Field>
          <Field label="Email"><Text type="email" value={data.email} onChange={set("email")} /></Field>
          <Field label="Phone"><Text value={data.phone} onChange={set("phone")} /></Field>
        </Grid>
      </Section>

      <Section title="Your status" note="Pick one.">
        <div style={{ display: "grid", gap: 8 }}>
          {CITIZENSHIP.map(c => (
            <label key={c.v} style={{
              display: "flex", gap: 10, alignItems: "center", cursor: "pointer",
              padding: "11px 14px", boxSizing: "border-box",
              border: `1px solid ${data.status === c.v ? T.blue : T.slate200}`,
              background: data.status === c.v ? T.blueLt : T.white, borderRadius: 8,
            }}>
              <input type="radio" name="i9status" checked={data.status === c.v}
                onChange={() => setData({ ...data, status: c.v })}
                style={{ width: 16, height: 16, accentColor: T.blue }} />
              <span style={{ fontSize: 13.5, color: T.slate800 }}>{c.label}</span>
            </label>
          ))}
        </div>

        {data.status === "permanent_resident" && (
          <Grid min={220}>
            <Field label="USCIS or Alien Registration Number">
              <Text value={data.uscis_number} onChange={set("uscis_number")} />
            </Field>
          </Grid>
        )}

        {data.status === "authorized_alien" && (
          <Grid min={220}>
            <Field label="Work authorization expires" hint="Leave blank if it does not expire.">
              <Text type="date" value={data.work_auth_expires} onChange={set("work_auth_expires")} />
            </Field>
            <Field label="USCIS or Alien Registration Number">
              <Text value={data.uscis_number} onChange={set("uscis_number")} />
            </Field>
            <Field label="Form I-94 admission number">
              <Text value={data.i94_number} onChange={set("i94_number")} />
            </Field>
            <Field label="Foreign passport number">
              <Text value={data.passport_number} onChange={set("passport_number")} />
            </Field>
            <Field label="Country that issued it">
              <Text value={data.passport_country} onChange={set("passport_country")} />
            </Field>
          </Grid>
        )}
      </Section>

      <Section title="Sign it">
        <div style={{ display: "grid", gap: 8 }}>
          <Check checked={data.attested} onChange={v => setData({ ...data, attested: v })}>
            I am aware that federal law provides for imprisonment and fines for false
            statements, or the use of false documents, in connection with the completion
            of this form. Everything I have entered above is true and correct.
          </Check>
          <Check checked={data.no_preparer} onChange={v => setData({ ...data, no_preparer: v })}>
            I did not use a preparer or translator.
          </Check>
        </div>
        <Grid min={220}>
          <Field label="Type your full name to sign">
            <Text value={data.signature} onChange={set("signature")} />
          </Field>
        </Grid>
      </Section>
    </div>
  );
}

function I9EmployerSection({ data, setData, canEdit, locked }) {
  const set = (k) => (v) => setData({ ...data, [k]: v });
  if (!canEdit) {
    return (
      <div style={{
        marginTop: 26, padding: "16px 18px", border: `1px dashed ${T.slate300}`,
        borderRadius: 10, background: T.slate50, fontSize: 13.5, color: T.slate600,
        lineHeight: 1.6, boxSizing: "border-box",
      }}>
        The second half is filled in by the agency after your original documents have
        been looked at in person. You do not need to do anything with it.
      </div>
    );
  }
  const dis = locked ? { pointerEvents: "none", opacity: 0.65 } : null;
  return (
    <div style={dis}>
      <Section title="Section 2 — the agency"
        note="Complete this only after looking at the original documents in person. Either one document from List A, or one from List B and one from List C.">
        <Grid min={200}>
          <Field label="List A document title"><Text value={data.a_title} onChange={set("a_title")} /></Field>
          <Field label="Issuing authority"><Text value={data.a_authority} onChange={set("a_authority")} /></Field>
          <Field label="Document number"><Text value={data.a_number} onChange={set("a_number")} /></Field>
          <Field label="Expiration date"><Text type="date" value={data.a_expires} onChange={set("a_expires")} /></Field>
        </Grid>
        <Grid min={200}>
          <Field label="List B document title"><Text value={data.b_title} onChange={set("b_title")} /></Field>
          <Field label="Issuing authority"><Text value={data.b_authority} onChange={set("b_authority")} /></Field>
          <Field label="Document number"><Text value={data.b_number} onChange={set("b_number")} /></Field>
          <Field label="Expiration date"><Text type="date" value={data.b_expires} onChange={set("b_expires")} /></Field>
        </Grid>
        <Grid min={200}>
          <Field label="List C document title"><Text value={data.c_title} onChange={set("c_title")} /></Field>
          <Field label="Issuing authority"><Text value={data.c_authority} onChange={set("c_authority")} /></Field>
          <Field label="Document number"><Text value={data.c_number} onChange={set("c_number")} /></Field>
          <Field label="Expiration date"><Text type="date" value={data.c_expires} onChange={set("c_expires")} /></Field>
        </Grid>
        <Grid min={220}>
          <Field label="First day of employment"><Text type="date" value={data.first_day} onChange={set("first_day")} /></Field>
          <Field label="Your name"><Text value={data.reviewer_name} onChange={set("reviewer_name")} /></Field>
          <Field label="Your title"><Text value={data.reviewer_title} onChange={set("reviewer_title")} /></Field>
        </Grid>
        <div style={{ marginTop: 14 }}>
          <Check checked={data.attested} onChange={v => setData({ ...data, attested: v })}>
            I have examined the original documents presented by this person, they appear
            genuine and to relate to the person named, and to the best of my knowledge
            this person is authorized to work in the United States.
          </Check>
        </div>
      </Section>
    </div>
  );
}

// ─── login packet ───────────────────────────────────────────────────────
// State Farm's New Agent/Agent Team Member Onboarding Packet, word for word.
// The lines that are different for each person live on their team record
// (sf_alias and the sf_* packet columns). Admins type them in at the top;
// the new hire sees them filled in. Team rows are readable only by admins and
// the person themselves, so nobody else sees the password or the pass. The
// template preview shows the blanks.

const PACKET_COLS = "first_name, last_name, sf_alias, sf_registration_number, sf_initial_password, sf_mfa_temp_pass, sf_mfa_temp_pass_from, sf_mfa_temp_pass_until";
const MONO = "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace";

// "10/05/2026 08:30 AM" in Central time, the way the packet prints it.
function packetTime(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const p = {};
  new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Chicago", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hour12: true,
  }).formatToParts(d).forEach(x => { p[x.type] = x.value; });
  return `${p.month}/${p.day}/${p.year} ${p.hour}:${p.minute} ${p.dayPeriod}`;
}

// A stored time as the value a date-and-time box expects, in the browser's time.
function toLocalInput(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const pad = n => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function fromLocalInput(v) {
  if (!v) return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

function packetDraft(row) {
  return {
    sf_alias: row?.sf_alias || "",
    sf_registration_number: row?.sf_registration_number || "",
    sf_initial_password: row?.sf_initial_password || "",
    sf_mfa_temp_pass: row?.sf_mfa_temp_pass || "",
    sf_mfa_temp_pass_from: toLocalInput(row?.sf_mfa_temp_pass_from),
    sf_mfa_temp_pass_until: toLocalInput(row?.sf_mfa_temp_pass_until),
  };
}

function PacketValue({ value, mono = false }) {
  if (!value) return <span style={{ color: T.slate400 }}>—</span>;
  return (
    <strong style={{ color: T.slate900, fontFamily: mono ? MONO : "inherit", wordBreak: "break-all" }}>
      {value}
    </strong>
  );
}

function PacketLink({ href }) {
  return (
    <a href={href} target="_blank" rel="noopener noreferrer" style={{
      color: T.blue, fontWeight: 700, textDecoration: "none", wordBreak: "break-all",
    }}>{href}</a>
  );
}

function LoginPacketForm({ teamId, isAdmin, preview, data, setData }) {
  const [rec, setRec] = useState(null);
  const [draft, setDraft] = useState(packetDraft(null));
  const [loading, setLoading] = useState(!preview);
  const [saving, setSaving] = useState(false);
  const [msg, setMsg] = useState(null);

  useEffect(() => {
    let alive = true;
    if (preview || !supabase || !teamId) { setLoading(false); return () => { alive = false; }; }
    (async () => {
      const { data: row, error } = await supabase
        .from("team").select(PACKET_COLS).eq("id", teamId).maybeSingle();
      if (!alive) return;
      if (error) setMsg(error.message || "Could not load the packet details.");
      setRec(row || null);
      setDraft(packetDraft(row));
      setLoading(false);
    })();
    return () => { alive = false; };
  }, [teamId, preview]);

  const set = (k) => (v) => setDraft({ ...draft, [k]: v });

  const saveDetails = async () => {
    if (!supabase || !teamId) return;
    setSaving(true); setMsg(null);
    const payload = {
      sf_alias: draft.sf_alias.trim() || null,
      sf_registration_number: draft.sf_registration_number.trim() || null,
      sf_initial_password: draft.sf_initial_password.trim() || null,
      sf_mfa_temp_pass: draft.sf_mfa_temp_pass.trim() || null,
      sf_mfa_temp_pass_from: fromLocalInput(draft.sf_mfa_temp_pass_from),
      sf_mfa_temp_pass_until: fromLocalInput(draft.sf_mfa_temp_pass_until),
    };
    const { data: rows, error } = await supabase
      .from("team").update(payload)
      .eq("id", teamId).eq("agency_id", AGENCY_ID)
      .select(PACKET_COLS);
    setSaving(false);
    if (error) { setMsg(error.message || "Could not save that."); return; }
    if (!rows || rows.length === 0) { setMsg("That did not save. The record may be blocked from changes."); return; }
    setRec(rows[0]);
    setDraft(packetDraft(rows[0]));
    setMsg("Saved.");
  };

  const v = preview ? null : rec;
  const name = v ? `${v.first_name || ""} ${v.last_name || ""}`.trim() : "";
  const sub = { paddingLeft: 22, margin: "6px 0 0" };
  const item = { marginTop: 4 };

  return (
    <div>
      {isAdmin && !preview && (
        <Section title="From the State Farm packet"
          note="These fill in the packet below. Only admins and this person can see them.">
          <Grid min={220}>
            <Field label="Alias (User ID)">
              <Text value={draft.sf_alias} onChange={set("sf_alias")} />
            </Field>
            <Field label="Registration Number">
              <Text value={draft.sf_registration_number} onChange={set("sf_registration_number")} />
            </Field>
            <Field label="Initial computer/workstation password">
              <Text value={draft.sf_initial_password} onChange={set("sf_initial_password")} />
            </Field>
            <Field label="Initial MFA Temporary Access Pass">
              <Text value={draft.sf_mfa_temp_pass} onChange={set("sf_mfa_temp_pass")} />
            </Field>
            <Field label="Good from">
              <Text type="datetime-local" value={draft.sf_mfa_temp_pass_from} onChange={set("sf_mfa_temp_pass_from")} />
            </Field>
            <Field label="Until">
              <Text type="datetime-local" value={draft.sf_mfa_temp_pass_until} onChange={set("sf_mfa_temp_pass_until")} />
            </Field>
          </Grid>
          <div style={{ marginTop: 14, display: "flex", gap: 10, alignItems: "center", flexWrap: "wrap" }}>
            <Button tone="quiet" onClick={saveDetails} disabled={saving || loading}>
              {saving ? "Saving..." : "Save details"}
            </Button>
            {msg && <span style={{ fontSize: 12.5, color: T.slate600 }}>{msg}</span>}
          </div>
        </Section>
      )}

      <div style={{
        marginTop: 18, padding: "18px 20px", border: `1px solid ${T.slate200}`,
        borderRadius: 10, background: T.white, fontSize: 13.5, lineHeight: 1.65,
        color: T.slate800, boxSizing: "border-box", minWidth: 0,
      }}>
        {loading && <div style={{ color: T.slate500, marginBottom: 10 }}>Loading...</div>}
        <div style={{ fontWeight: 700, color: T.slate900 }}>New Agent/Agent Team Member Onboarding Packet</div>
        <div style={{ fontWeight: 700, color: T.slate900 }}>CONFIDENTIAL</div>
        <div>- Distribution on a Business Need to Know Basis Only -</div>

        <div style={{ marginTop: 16 }}>
          <div style={{ fontWeight: 700, color: T.slate900 }}>
            This document should only be given to {name || <span style={{ color: T.slate400 }}>—</span>}
          </div>
          <div>Your alias (User ID) is: <PacketValue value={v?.sf_alias} /></div>
          <div>Your Registration Number is: <PacketValue value={v?.sf_registration_number} /></div>
          <div>Your initial computer/workstation password: <PacketValue value={v?.sf_initial_password} mono /></div>
          <div>
            Your initial MFA Temporary Access Pass: <PacketValue value={v?.sf_mfa_temp_pass} mono />
            {" "}Good from: <PacketValue value={packetTime(v?.sf_mfa_temp_pass_from)} />
            {" "}Until: <PacketValue value={packetTime(v?.sf_mfa_temp_pass_until)} />
          </div>
        </div>

        <div style={{ marginTop: 16, fontWeight: 700, color: T.slate900 }}>
          Compliance with State Farm’s Enterprise Information Security Policy (EISP) is mandatory for
          all Agents and Team Members. COMPLETE ALL STEPS ON THIS PAGE. Call the New Team Member
          Support Hotline: 1-833-572-0397 for assistance
        </div>

        <p style={{ margin: "16px 0 0" }}>
          If you have a new team member who will be working in office on a previously used or shared
          workstation, please visit: <PacketLink href="http://s.f/yubikeyinoffice" />
        </p>
        <p style={{ margin: "12px 0 0" }}>
          If new user is logging into a new workstation remotely, follow the instructions found
          at <PacketLink href="http://s.f/remoteuserabs" />
        </p>

        <ol style={{ paddingLeft: 22, margin: "16px 0 0" }}>
          <li style={item}>
            <strong style={{ color: T.slate900 }}>Logon instructions for in-office users with a new workstation:</strong>
            <ol type="a" style={sub}>
              <li style={item}>At the workstation logon screen enter the alias and password provided above</li>
              <li style={item}>
                When prompted to change your password, create a new password following these standards:
                <ul style={sub}>
                  <li style={item}>The password should be a minimum of 16 characters</li>
                  <li style={item}>
                    The password must contain at least one of each of the following: a capital letter,
                    a lower case letter, a numeric character, and a special character (no blank spaces allowed)
                  </li>
                  <li style={item}>
                    <strong>Do not</strong> use a name, a dictionary word, or your State Farm alias as part
                    of your password.
                  </li>
                </ul>
              </li>
            </ol>
          </li>
          <li style={{ marginTop: 14 }}>
            <strong style={{ color: T.slate900 }}>Setup of ABS Password:</strong>
            <ol type="a" style={sub}>
              <li style={item}>
                Once logged in, open a web browser and enter the following URL: <PacketLink href="https://s.f/spc" />
              </li>
              <li style={item}>Sign in and select <strong>Change ABS/Dial-in password</strong> option</li>
              <li style={item}>
                Create a new password in the <strong>Enter new password</strong> field then enter again to confirm
              </li>
              <li style={item}>A Success confirmation pop up should be displayed</li>
            </ol>
          </li>
          <li style={{ marginTop: 14 }}>
            <strong style={{ color: T.slate900 }}>Additional items:</strong>
            <ol type="a" style={sub}>
              <li style={item}>
                Open Web Browser and navigate to: <PacketLink href="https://s.f/agencysecuritycheckpoint" />
                <ul style={sub}>
                  <li style={item}>
                    Select <strong>New Agent/Agent team member Onboarding Packet</strong> on the left side of the screen
                  </li>
                  <li style={item}><strong>Complete all tasks in the Onboarding Packet to be compliant</strong></li>
                </ul>
              </li>
              <li style={item}>
                Visit <PacketLink href="https://s.f/yubikeyagency" /> for further assistance with YubiKeys and MFA technology
              </li>
            </ol>
          </li>
        </ol>
      </div>

      <div style={{ marginTop: 16 }}>
        <Check checked={data.done} onChange={x => setData({ ...data, done: x })}>
          I completed all steps on this page.
        </Check>
      </div>
    </div>
  );
}

// ─── the form shell ─────────────────────────────────────────────────────

// ─── W-4 (2026) ─────────────────────────────────────────────────────────
// Not the W-4 itself: the answers Peter needs to fill in the official W-4 in
// SurePayroll. Name, address and Social Security number are already on file,
// so only the choices on the IRS form are asked. The worksheets on the IRS
// form's later pages are linked, not rebuilt.

const W4_FILING = [
  { v: "single", label: "Single or Married filing separately" },
  { v: "joint", label: "Married filing jointly or Qualifying surviving spouse" },
  { v: "head", label: "Head of household (only if you're unmarried and pay more than half the costs of keeping up a home for yourself and a qualifying individual)" },
];
const W4_PER_CHILD = 2200;
const W4_PER_OTHER = 500;
const W4_IRS_PDF = "https://www.irs.gov/pub/irs-pdf/fw4.pdf";

function w4Money(v) {
  const n = Number(String(v || "").replace(/[^0-9.]/g, ""));
  return Number.isFinite(n) ? n : 0;
}
function w4Count(v) {
  const n = parseInt(String(v || "").replace(/[^0-9]/g, ""), 10);
  return Number.isFinite(n) && n > 0 ? n : 0;
}
export function w4Step3Total(data) {
  return w4Count(data.children) * W4_PER_CHILD
       + w4Count(data.other_dependents) * W4_PER_OTHER
       + w4Money(data.other_credits);
}

function W4Form({ data, setData }) {
  const set = (k) => (v) => setData({ ...data, [k]: v });
  const total = w4Step3Total(data);

  return (
    <div>
      <div style={{ fontSize: 13, color: T.slate600, lineHeight: 1.55, marginTop: 4 }}>
        Your answers here are used to fill out your W-4 in SurePayroll.
      </div>

      <Section title="Step 1: Filing status">
        <div style={{ display: "grid", gap: 8 }}>
          {W4_FILING.map(f => (
            <label key={f.v} style={{
              display: "flex", gap: 10, alignItems: "center", cursor: "pointer",
              padding: "11px 14px", boxSizing: "border-box",
              border: `1px solid ${data.filing_status === f.v ? T.blue : T.slate200}`,
              background: data.filing_status === f.v ? T.blueLt : T.white, borderRadius: 8,
            }}>
              <input type="radio" name="w4filing" checked={data.filing_status === f.v}
                onChange={() => setData({ ...data, filing_status: f.v })}
                style={{ width: 16, height: 16, accentColor: T.blue, flexShrink: 0 }} />
              <span style={{ fontSize: 13.5, color: T.slate800 }}>{f.label}</span>
            </label>
          ))}
        </div>
      </Section>

      <Section title="Step 2: Multiple jobs or spouse works"
        note="Only if you hold more than one job at a time, or you're married filing jointly and your spouse also works.">
        <Check checked={data.two_jobs} onChange={set("two_jobs")}>
          There are only two jobs total. Check this box on the W-4 for both jobs.
        </Check>
        <div style={{ fontSize: 12, color: T.slate500, marginTop: 8, lineHeight: 1.5 }}>
          More than two jobs? Use the Multiple Jobs Worksheet on page 3 of the{" "}
          <a href={W4_IRS_PDF} target="_blank" rel="noreferrer" style={{ color: T.blue }}>IRS form</a>{" "}
          and put the result in Step 4(c).
        </div>
      </Section>

      <Section title="Step 3: Claim dependent and other credits"
        note="If your total income will be $200,000 or less ($400,000 or less if married filing jointly).">
        <Grid min={200}>
          <Field label="Qualifying children under age 17" hint={`Number of children. $${W4_PER_CHILD.toLocaleString()} each.`}>
            <Text value={data.children} onChange={set("children")} placeholder="0" />
          </Field>
          <Field label="Other dependents" hint={`Number of dependents. $${W4_PER_OTHER} each.`}>
            <Text value={data.other_dependents} onChange={set("other_dependents")} placeholder="0" />
          </Field>
          <Field label="Other credits" hint="Step 3(b). Dollar amount, if any.">
            <Text value={data.other_credits} onChange={set("other_credits")} placeholder="$0" />
          </Field>
          <Field label="Step 3 total">
            <div style={{ fontSize: 14, fontWeight: 600, color: T.slate800, padding: "9px 0" }}>
              ${total.toLocaleString()}
            </div>
          </Field>
        </Grid>
      </Section>

      <Section title="Step 4: Other adjustments">
        <Grid min={200}>
          <Field label="(a) Other income (not from jobs)" hint="For the year, if any.">
            <Text value={data.other_income} onChange={set("other_income")} placeholder="$0" />
          </Field>
          <Field label="(b) Deductions" hint="From the Deductions Worksheet on page 4 of the IRS form. Leave blank to use the standard deduction.">
            <Text value={data.deductions} onChange={set("deductions")} placeholder="$0" />
          </Field>
          <Field label="(c) Extra withholding" hint="Each pay period, if any.">
            <Text value={data.extra_withholding} onChange={set("extra_withholding")} placeholder="$0" />
          </Field>
        </Grid>
        <div style={{ marginTop: 12 }}>
          <Check checked={data.exempt} onChange={set("exempt")}>
            I claim exemption from withholding for 2026. I had no federal income tax liability in 2025 and expect none in 2026.
          </Check>
        </div>
      </Section>

    </div>
  );
}

function readyToSubmit(formType, data, secure) {
  if (formType === "login_packet") return !!data.done;
  if (formType === "non_compete" || formType === "handbook_ack") return !!data.agreed;
  if (formType === "i9") return !!data.attested && !!data.signature && !!data.status;
  if (formType === "w4") return !!data.filing_status;
  if (formType === "combined_onboarding") {
    return !!data.why_statement &&
      (secure.banks || []).some(b => b.bank_name && b.account_number && b.routing_number);
  }
  return false;
}

function FormShell({ form, teamId, meId, isAdmin, submission, docs, onDone, onBack, backLabel = "Back to forms", preview = false }) {
  const [data, setData] = useState(submission?.data || {});
  const [employer, setEmployer] = useState(submission?.employer_section || {});
  const [secure, setSecure] = useState({ ssn: "", banks: [{ ...EMPTY_BANK }] });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);
  // The template page shows a blank preview: nothing loaded, nothing saved.
  const locked = !preview && !!submission?.locked_at;
  const doc = form.id === "non_compete" ? docs.non_compete
            : form.id === "handbook_ack" ? docs.handbook : null;

  const save = async (submit) => {
    if (!supabase) return;
    setBusy(true); setErr(null);
    try {
      const cycleKey =
        (form.id === "non_compete" || form.id === "handbook_ack") && doc ? `v${doc.version}`
        : "";

      // The Onboarding form locks last. Its Social Security number and bank
      // details save first, so a failed save leaves the form open with
      // nothing lost, instead of locked with no bank details on file.
      const lockLast = submit && form.id === "combined_onboarding";

      const row = {
        agency_id: AGENCY_ID,
        team_id: teamId,
        form_type: form.id,
        cycle_key: cycleKey,
        document_id: doc ? doc.id : null,
        data: form.id === "w4" ? { ...data, step3_total: w4Step3Total(data) } : data,
        status: submit && !lockLast ? "submitted" : "in_progress",
      };
      if (form.id === "i9" && isAdmin && employer && employer.attested) {
        row.employer_section = employer;
        row.employer_completed_by = meId;
        row.employer_completed_at = new Date().toISOString();
      } else if (form.id === "i9") {
        row.employer_section = submission?.employer_section || null;
      }

      const { data: saved, error } = await supabase
        .from("team_form_submissions")
        .upsert(row, { onConflict: "team_id,form_type,cycle_key" })
        .select()
        .maybeSingle();
      if (error) throw error;

      // Social Security number and bank details go to their own table and are
      // never read back to the person who typed them. The save runs in the
      // database (save_onboarding_secure) so the hire can write it without
      // being able to read the table, and it reuses a number already on file.
      if (lockLast && saved) {
        const { error: se } = await supabase.rpc("save_onboarding_secure", {
          p_submission_id: saved.id,
          p_ssn: secure.ssn || null,
          p_banks: (secure.banks || []).filter(b => b.bank_name && b.account_number),
        });
        if (se) throw se;
        const { data: lockedRows, error: le } = await supabase
          .from("team_form_submissions")
          .update({ status: "submitted" })
          .eq("id", saved.id)
          .select("id");
        if (le) throw le;
        if (!lockedRows || lockedRows.length === 0) {
          throw new Error("Your answers saved, but the form did not lock. Press Submit again.");
        }
      }

      if (submission?.id) {
        await supabase.from("team_form_edits").insert({
          submission_id: submission.id,
          agency_id: AGENCY_ID,
          field_path: form.id,
          new_value: submit ? "submitted" : "saved",
          edited_by: meId,
        });
      }
      onDone();
    } catch (e) {
      setErr(e?.message || "Could not save that.");
    } finally {
      setBusy(false);
    }
  };

  const canSubmit = form.id === "i9" && isAdmin && submission?.employee_submitted_at
    ? !!employer.attested
    : readyToSubmit(form.id, data, secure);

  return (
    <div>
      <button onClick={onBack} style={{
        background: "none", border: "none", padding: 0, cursor: "pointer",
        color: T.slate500, fontSize: 13, fontWeight: 600, fontFamily: "inherit",
      }}>{backLabel}</button>

      <div style={{ marginTop: 14, display: "flex", gap: 10, alignItems: "center", flexWrap: "wrap" }}>
        <div style={{ fontSize: 19, fontWeight: 700, color: T.slate900, letterSpacing: "-0.01em" }}>
          {form.label}
        </div>
        {locked && <Pill state="complete" />}
      </div>
      <div style={{ fontSize: 13, color: T.slate500, marginTop: 4 }}>{form.blurb}</div>

      {locked && (
        <div style={{
          marginTop: 14, padding: "11px 14px", background: T.slate50,
          border: `1px solid ${T.slate200}`, borderRadius: 8, fontSize: 13,
          color: T.slate600, boxSizing: "border-box",
        }}>
          This was submitted on {new Date(submission.locked_at).toLocaleDateString()} and is locked.
          {submission.retention_until && ` Kept until ${new Date(submission.retention_until).toLocaleDateString()}.`}
        </div>
      )}

      {preview && (
        <div style={{
          marginTop: 12, padding: "10px 14px", background: T.blueLt, color: T.slate700,
          borderRadius: 8, fontSize: 13, boxSizing: "border-box",
        }}>
          Preview of what the new hire fills in. Nothing here is saved.
        </div>
      )}

      <div style={locked && form.id !== "i9" ? { pointerEvents: "none", opacity: 0.65 } : null}>
        {form.id === "login_packet" &&
          <LoginPacketForm teamId={teamId} isAdmin={isAdmin} preview={preview} data={data} setData={setData} />}
        {form.id === "combined_onboarding" &&
          <CombinedForm data={data} setData={setData} secure={secure} setSecure={setSecure} />}
        {form.id === "w4" && <W4Form data={data} setData={setData} />}
        {form.id === "non_compete" && <NonCompeteForm doc={doc} data={data} setData={setData} />}
        {form.id === "handbook_ack" && <HandbookForm doc={doc} data={data} setData={setData} />}
        {form.id === "i9" && (
          <>
            <I9EmployeeSection data={data} setData={setData} locked={!!submission?.employee_submitted_at} />
            <I9EmployerSection data={employer} setData={setEmployer} canEdit={isAdmin}
              locked={!!submission?.employer_completed_at} />
          </>
        )}
      </div>

      {err && (
        <div style={{
          marginTop: 16, padding: "11px 14px", background: T.redLt, color: "#8E2A22",
          borderRadius: 8, fontSize: 13, boxSizing: "border-box",
        }}>{err}</div>
      )}

      {!locked && !preview && (
        <div style={{ marginTop: 24, display: "flex", gap: 10, flexWrap: "wrap" }}>
          <Button onClick={() => save(true)} disabled={busy || !canSubmit}>
            {busy ? "Saving..." : "Submit"}
          </Button>
          {form.id === "combined_onboarding" && (
            <Button tone="quiet" onClick={() => save(false)} disabled={busy}>Save and finish later</Button>
          )}
        </div>
      )}
      {!locked && !canSubmit && (
        <div style={{ fontSize: 12, color: T.slate500, marginTop: 10 }}>
          Fill in everything above to submit.
        </div>
      )}
    </div>
  );
}

// ─── the list, and the destroy button ───────────────────────────────────

export default function TeamForms({ teamId: teamIdProp, isAdmin: isAdminProp, embedded = false, onlyForm = null, onClose = null, preview = false }) {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";

  // Who is signed in, and are they allowed to see everyone. Both answers come
  // from the database, which is the same place the policies read them from.
  // Passing them in as props would only ever be a second, weaker copy.
  const [meId, setMeId] = useState(null);
  const [isAdmin, setIsAdmin] = useState(!!isAdminProp);
  useEffect(() => {
    let alive = true;
    (async () => {
      if (!supabase) return;
      const [{ data: me }, { data: admin }] = await Promise.all([
        supabase.rpc("current_team_member_id"),
        supabase.rpc("is_agency_admin"),
      ]);
      if (!alive) return;
      setMeId(me || null);
      if (isAdminProp === undefined) setIsAdmin(!!admin);
    })();
    return () => { alive = false; };
  }, [isAdminProp]);

  const teamId = teamIdProp || meId;

  const [rows, setRows] = useState([]);
  const [subs, setSubs] = useState([]);
  const [docs, setDocs] = useState({});
  const [hasSecure, setHasSecure] = useState(0);
  // The open form rides in the URL (?form=i9), so a link can go straight to it.
  // In a pop-up (onlyForm) the open form lives here, not in the page address,
  // and closing it closes the pop-up.
  const [urlOpen, setUrlOpen] = useTabParam("form", null, FORMS.map(f => f.id));
  const [localOpen, setLocalOpen] = useState(onlyForm);
  const open = onlyForm ? localOpen : urlOpen;
  const setOpen = onlyForm
    ? (v) => { setLocalOpen(v); if (!v && onClose) onClose(); }
    : setUrlOpen;
  const [loading, setLoading] = useState(true);
  const [purging, setPurging] = useState(false);
  const [notice, setNotice] = useState(null);

  const load = useCallback(async () => {
    if (!supabase || !teamId) { setLoading(false); return; }
    setLoading(true);
    const [st, sb, dc] = await Promise.all([
      supabase.from("v_team_form_status").select("*").eq("team_id", teamId),
      supabase.from("team_form_submissions").select("*").eq("team_id", teamId),
      supabase.from("form_documents").select("*").eq("is_current", true),
    ]);
    setRows(st?.data || []);
    setSubs(sb?.data || []);
    const byType = {};
    (dc?.data || []).forEach(d => { byType[d.doc_type] = d; });
    setDocs(byType);

    if (isAdmin) {
      const ids = (sb?.data || []).map(s => s.id);
      if (ids.length) {
        const { count } = await supabase
          .from("team_form_secure")
          .select("id", { count: "exact", head: true })
          .in("submission_id", ids);
        setHasSecure(count || 0);
      } else setHasSecure(0);
    }
    setLoading(false);
  }, [teamId, isAdmin]);

  useEffect(() => { load(); }, [load]);

  const destroy = async () => {
    if (!supabase) return;
    const ok = window.confirm(
      "This deletes the Social Security number and every bank account on file for this person. " +
      "It cannot be undone. Make sure SurePayroll is set up first."
    );
    if (!ok) return;
    setPurging(true);
    const { data, error } = await supabase.rpc("purge_team_form_secure", { p_team_id: teamId });
    setPurging(false);
    setNotice(error ? (error.message || "Could not do that.")
                    : `Destroyed. ${data?.deleted || 0} record(s) removed.`);
    load();
  };

  if (loading) {
    return <div style={{ padding: _pad, color: T.slate500, fontSize: 14 }}>Loading forms...</div>;
  }
  if (!teamId) {
    return (
      <div style={{ padding: _pad, color: T.slate500, fontSize: 14, lineHeight: 1.6 }}>
        Your sign-in is not linked to a team record yet, so there are no forms to show.
      </div>
    );
  }

  const openForm = open && FORMS.find(f => f.id === open);
  const subFor = (id) => subs.find(s => s.form_type === id && s.status !== "superseded") || null;

  return (
    <div style={{ padding: embedded ? _pad : _pad, maxWidth: 860, minWidth: 0 }}>
      {openForm ? (
        <FormShell
          form={openForm}
          teamId={teamId}
          meId={meId}
          isAdmin={isAdmin}
          submission={preview ? null : subFor(openForm.id)}
          preview={preview}
          docs={docs}
          onBack={() => setOpen(null)}
          onDone={() => { setOpen(null); load(); }}
          backLabel={onlyForm ? "Close" : "Back to forms"}
        />
      ) : (
        <>
          <div style={{ fontSize: 13.5, color: T.slate600, lineHeight: 1.6, marginBottom: 18 }}>
            {isAdmin ? "Everything this team member has filled in." :
              "Everything the agency needs from you. Anything marked below still needs doing."}
          </div>

          <div style={{ display: "grid", gap: 10 }}>
            {FORMS.map(f => {
              const r = rows.find(x => x.form_type === f.id) || {};
              const s = r.state || "action_needed";
              // The login packet only matters while someone is onboarding.
              if (f.id === "login_packet" && s === "waived") return null;
              return (
                <div key={f.id} style={{
                  display: "flex", gap: 12, alignItems: "center", flexWrap: "wrap",
                  padding: "14px 16px", border: `1px solid ${T.slate200}`,
                  borderRadius: 10, background: T.white, boxSizing: "border-box",
                }}>
                  <div style={{ flex: "1 1 220px", minWidth: 0 }}>
                    <div style={{ fontSize: 14.5, fontWeight: 600, color: T.slate900 }}>{f.label}</div>
                    <div style={{ fontSize: 12.5, color: T.slate500, marginTop: 3, lineHeight: 1.45 }}>
                      {f.blurb}
                    </div>
                    {r.due_date && s !== "complete" && (
                      <div style={{ fontSize: 12, color: T.slate500, marginTop: 4 }}>
                        Due {new Date(r.due_date).toLocaleDateString()}
                      </div>
                    )}
                    {r.last_completed_at && s === "complete" && (
                      <div style={{ fontSize: 12, color: T.slate500, marginTop: 4 }}>
                        Last done {new Date(r.last_completed_at).toLocaleDateString()}
                      </div>
                    )}
                  </div>
                  <Pill state={s} />
                  <Button tone={s === "complete" ? "quiet" : "primary"} onClick={() => setOpen(f.id)}>
                    {s === "complete" ? "View" : "Fill in"}
                  </Button>
                </div>
              );
            })}
          </div>

          {isAdmin && (
            <div style={{
              marginTop: 24, padding: "16px 18px", borderRadius: 10,
              border: `1px solid ${hasSecure ? T.red : T.slate200}`,
              background: hasSecure ? T.redLt : T.slate50, boxSizing: "border-box",
            }}>
              <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>
                Payroll details
              </div>
              <div style={{ fontSize: 13, color: T.slate700, marginTop: 6, lineHeight: 1.55 }}>
                {hasSecure
                  ? "A Social Security number and bank details are stored for this person. Enter them in SurePayroll, then destroy them."
                  : "Nothing sensitive is stored for this person."}
              </div>
              {hasSecure > 0 && (
                <div style={{ marginTop: 14 }}>
                  <Button tone="danger" onClick={destroy} disabled={purging}>
                    {purging ? "Destroying..." : "Destroy payroll details"}
                  </Button>
                </div>
              )}
              {notice && (
                <div style={{ fontSize: 12.5, color: T.slate600, marginTop: 10 }}>{notice}</div>
              )}
            </div>
          )}
        </>
      )}
    </div>
  );
}
