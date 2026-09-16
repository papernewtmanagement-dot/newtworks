import { useState, useEffect, useCallback } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import { mdToHtml } from "../lib/markdown.js";

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

const FORMS = [
  { id: "combined_onboarding", label: "Onboarding form",
    blurb: "Your details, your story, and payroll setup." },
  { id: "non_compete", label: "Non-compete",
    blurb: "Read it and agree. A copy is emailed to you." },
  { id: "i9", label: "I-9",
    blurb: "Work authorization. Your documents are checked in person." },
  { id: "handbook_ack", label: "Handbook",
    blurb: "Read the current handbook and confirm." },
  { id: "annual_certification", label: "Annual certification",
    blurb: "Confirm you completed it in ABS." },
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

function Section({ title, note, children }) {
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

function Check({ checked, onChange, children }) {
  return (
    <label style={{
      display: "flex", gap: 10, alignItems: "flex-start", cursor: "pointer",
      padding: "12px 14px", border: `1px solid ${checked ? T.blue : T.slate200}`,
      background: checked ? T.blueLt : T.white, borderRadius: 8, boxSizing: "border-box",
    }}>
      <input type="checkbox" checked={!!checked} onChange={e => onChange(e.target.checked)}
        style={{ marginTop: 2, width: 16, height: 16, flexShrink: 0, accentColor: T.blue }} />
      <span style={{ fontSize: 13.5, color: T.slate800, lineHeight: 1.5 }}>{children}</span>
    </label>
  );
}

// ─── the combined onboarding form ───────────────────────────────────────
// Bio, the why statement, and the payroll half. Peter explains the why idea
// at orientation and this is filled in afterwards.

const RANKABLE = ["Words of Affirmation", "Paid Time Off", "Awards", "Bonuses"];
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
          {RANKABLE.map(r => (
            <Field key={r} label={r}>
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
          <Field label="If we sent you a gift card, where to?">
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
        <Grid min={240}>
          <Field label="Social Security number" hint="Numbers only.">
            <Text value={secure.ssn} onChange={v => setSecure({ ...secure, ssn: v })} placeholder="000000000" />
          </Field>
        </Grid>

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

// ─── annual certification ───────────────────────────────────────────────
// Done in ABS. All we record here is that it was done, and when.

function CertificationForm({ data, setData }) {
  return (
    <div>
      <div style={{
        marginTop: 18, padding: "16px 18px", border: `1px solid ${T.slate200}`,
        borderRadius: 10, background: T.slate50, fontSize: 13.5, color: T.slate700,
        lineHeight: 1.6, boxSizing: "border-box",
      }}>
        The annual certification is completed in ABS, not here. It covers the
        felony-conviction certification required under the Federal Crime Bill and
        Section 19 of the Federal Deposit Insurance Act. Complete it in ABS first,
        then record it below. Nothing about your answers is stored in Newtworks.
      </div>
      <Grid min={220}>
        <Field label="Date you completed it in ABS">
          <Text type="date" value={data.completed_on} onChange={v => setData({ ...data, completed_on: v })} />
        </Field>
      </Grid>
      <div style={{ marginTop: 16 }}>
        <Check checked={data.agreed} onChange={v => setData({ ...data, agreed: v })}>
          I completed the State Farm annual certification in ABS on the date above.
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

// ─── the form shell ─────────────────────────────────────────────────────

function readyToSubmit(formType, data, secure) {
  if (formType === "non_compete" || formType === "handbook_ack") return !!data.agreed;
  if (formType === "annual_certification") return !!data.agreed && !!data.completed_on;
  if (formType === "i9") return !!data.attested && !!data.signature && !!data.status;
  if (formType === "combined_onboarding") {
    return !!data.why_statement && !!secure.ssn &&
      (secure.banks || []).some(b => b.bank_name && b.account_number && b.routing_number);
  }
  return false;
}

function FormShell({ form, teamId, meId, isAdmin, submission, docs, onDone, onBack }) {
  const [data, setData] = useState(submission?.data || {});
  const [employer, setEmployer] = useState(submission?.employer_section || {});
  const [secure, setSecure] = useState({ ssn: "", banks: [{ ...EMPTY_BANK }] });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);

  const locked = !!submission?.locked_at;
  const doc = form.id === "non_compete" ? docs.non_compete
            : form.id === "handbook_ack" ? docs.handbook : null;

  const save = async (submit) => {
    if (!supabase) return;
    setBusy(true); setErr(null);
    try {
      const cycleKey =
        form.id === "annual_certification" ? String(new Date().getFullYear())
        : (form.id === "non_compete" || form.id === "handbook_ack") && doc ? `v${doc.version}`
        : "";

      const row = {
        agency_id: AGENCY_ID,
        team_id: teamId,
        form_type: form.id,
        cycle_key: cycleKey,
        document_id: doc ? doc.id : null,
        data,
        status: submit ? "submitted" : "in_progress",
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
      // never read back to the person who typed them.
      if (submit && form.id === "combined_onboarding" && saved && secure.ssn) {
        const { error: se } = await supabase.from("team_form_secure").insert({
          submission_id: saved.id,
          agency_id: AGENCY_ID,
          ssn: secure.ssn,
          banks: (secure.banks || []).filter(b => b.bank_name && b.account_number),
        });
        if (se) throw se;
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
      }}>Back to forms</button>

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

      <div style={locked && form.id !== "i9" ? { pointerEvents: "none", opacity: 0.65 } : null}>
        {form.id === "combined_onboarding" &&
          <CombinedForm data={data} setData={setData} secure={secure} setSecure={setSecure} />}
        {form.id === "non_compete" && <NonCompeteForm doc={doc} data={data} setData={setData} />}
        {form.id === "handbook_ack" && <HandbookForm doc={doc} data={data} setData={setData} />}
        {form.id === "annual_certification" && <CertificationForm data={data} setData={setData} />}
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

      {!locked && (
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

export default function TeamForms({ teamId: teamIdProp, isAdmin: isAdminProp, embedded = false }) {
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
  const [open, setOpen] = useState(null);
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
          submission={subFor(openForm.id)}
          docs={docs}
          onBack={() => setOpen(null)}
          onDone={() => { setOpen(null); load(); }}
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
