import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useState, useEffect, useMemo, useCallback } from "react";

// =====================================================================
// TimeClock.jsx — Hourly staff time clock
// Two views: Kiosk (name tile + PIN pad, self-clock) and Admin (timesheet)
// Week boundary: Sunday 00:00 -> Saturday 23:59
// One time_clock_entry row = one continuous block of paid work
// Lunches = gaps between blocks (clock out for lunch, clock back in)
// =====================================================================

// ---------- date / week helpers ----------
function startOfSundayWeek(date) {
  const d = new Date(date);
  d.setHours(0, 0, 0, 0);
  const dow = d.getDay(); // 0 = Sunday
  d.setDate(d.getDate() - dow);
  return d;
}
function endOfSaturdayWeek(date) {
  const start = startOfSundayWeek(date);
  const end = new Date(start);
  end.setDate(end.getDate() + 7);
  return end; // exclusive
}
function addDays(date, days) {
  const d = new Date(date);
  d.setDate(d.getDate() + days);
  return d;
}
function fmtTime(iso) {
  if (!iso) return "—";
  return new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}
function fmtHM(hours) {
  if (!Number.isFinite(hours)) return "0:00";
  const sign = hours < 0 ? "-" : "";
  const abs = Math.abs(hours);
  const h = Math.floor(abs);
  const m = Math.round((abs - h) * 60);
  if (m === 60) return `${sign}${h + 1}:00`;
  return `${sign}${h}:${String(m).padStart(2, "0")}`;
}
function hoursBetween(inIso, outIso) {
  if (!inIso || !outIso) return 0;
  return (new Date(outIso) - new Date(inIso)) / 3_600_000;
}

// ---------- current user (for edit history + admin gating) ----------
function useCurrentUser() {
  const [user, setUser] = useState(null);
  const [loading, setLoading] = useState(true);
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data: authData } = await supabase.auth.getUser();
      const authUserId = authData?.user?.id;
      if (!authUserId) { if (!cancelled) { setUser(null); setLoading(false); } return; }
      const { data: rows } = await supabase
        .from("users")
        .select("id, role, full_name, email")
        .eq("auth_user_id", authUserId)
        .eq("agency_id", AGENCY_ID)
        .limit(1);
      if (!cancelled) {
        setUser(rows?.[0] || null);
        setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, []);
  return { user, loading };
}

// ---------- hourly staff status ----------
function useHourlyStaff() {
  const [staff, setStaff] = useState([]);
  const [loading, setLoading] = useState(true);
  const reload = useCallback(async () => {
    setLoading(true);
    const { data, error } = await supabase
      .from("v_time_clock_status")
      .select("*")
      .order("first_name");
    if (!error) setStaff(data || []);
    setLoading(false);
  }, []);
  useEffect(() => { reload(); }, [reload]);
  return { staff, loading, reload };
}

// =====================================================================
// MAIN
// =====================================================================
export default function TimeClock() {
  const { user, loading: userLoading } = useCurrentUser();
  const canSeeAdmin = !!user && ["owner", "manager"].includes(user.role);
  const [tab, setTab] = useState("kiosk");

  return (
    <div className="p-4 md:p-6 max-w-6xl mx-auto">
      <div className="flex items-center justify-between mb-4 flex-wrap gap-2">
        <div>
          <h1 className="text-2xl font-semibold text-slate-900">Time Clock</h1>
          <p className="text-sm text-slate-500">
            Hourly team clock in / out · week runs Sun–Sat · lunch = clock out then back in
          </p>
        </div>
        {!userLoading && canSeeAdmin && (
          <div className="flex gap-1 rounded-lg bg-slate-100 p-1">
            <button
              onClick={() => setTab("kiosk")}
              className={`px-3 py-1.5 text-sm rounded-md transition ${tab === "kiosk" ? "bg-white shadow text-slate-900" : "text-slate-600"}`}
            >
              Kiosk
            </button>
            <button
              onClick={() => setTab("admin")}
              className={`px-3 py-1.5 text-sm rounded-md transition ${tab === "admin" ? "bg-white shadow text-slate-900" : "text-slate-600"}`}
            >
              Admin
            </button>
          </div>
        )}
      </div>

      {tab === "kiosk" || !canSeeAdmin
        ? <KioskView />
        : <AdminView userId={user?.id} />}
    </div>
  );
}

// =====================================================================
// KIOSK VIEW — name tiles -> PIN pad -> punch
// =====================================================================
function KioskView() {
  const { staff, loading, reload } = useHourlyStaff();
  const [selected, setSelected] = useState(null);
  const [pin, setPin] = useState("");
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState(null);

  // refresh status every 30s so the on-clock counters stay live
  useEffect(() => {
    const t = setInterval(reload, 30_000);
    return () => clearInterval(t);
  }, [reload]);

  // clear the success splash after a few seconds
  useEffect(() => {
    if (!result?.ok) return;
    const t = setTimeout(() => setResult(null), 5000);
    return () => clearTimeout(t);
  }, [result]);

  function pickStaff(s) { setSelected(s); setPin(""); setResult(null); }
  function appendDigit(d) {
    if (pin.length >= 4) return;
    const next = pin + d;
    setPin(next);
    if (next.length === 4) submitPunch(next);
  }
  function backspace() { setPin((p) => p.slice(0, -1)); }
  function cancel() { setSelected(null); setPin(""); setBusy(false); }

  async function submitPunch(fullPin) {
    if (!selected) return;
    setBusy(true);
    const { data, error } = await supabase.rpc("time_clock_punch", {
      p_staff_id: selected.staff_id,
      p_pin: fullPin,
    });
    setBusy(false);
    if (error) {
      setResult({ ok: false, error: "rpc_error", message: error.message });
      setPin("");
      return;
    }
    setResult(data);
    setPin("");
    if (data?.ok) {
      setTimeout(() => { setSelected(null); reload(); }, 1500);
    }
  }

  if (loading) return <div className="text-center text-slate-500 py-12">Loading…</div>;

  if (!staff.length) {
    return (
      <div className="rounded-xl border border-dashed border-slate-300 bg-slate-50 p-8 text-center">
        <p className="text-slate-700 font-medium">No hourly team members yet</p>
        <p className="text-sm text-slate-500 mt-1">
          Add an HOURLY staff member in Team to see them here.
        </p>
      </div>
    );
  }

  // success splash takes over briefly after a punch
  if (result?.ok) {
    const isIn = result.action === "clock_in";
    return (
      <div className={`rounded-2xl p-8 text-center ${isIn ? "bg-emerald-50 border border-emerald-200" : "bg-sky-50 border border-sky-200"}`}>
        <div className={`text-5xl mb-3 ${isIn ? "text-emerald-600" : "text-sky-600"}`}>✓</div>
        <div className="text-xl font-semibold text-slate-900">
          {result.staff_name} {isIn ? "clocked in" : "clocked out"}
        </div>
        <div className="text-sm text-slate-600 mt-1">
          at {fmtTime(result.at)}
          {!isIn && result.hours_this_block != null && (
            <> · this block: <span className="font-medium">{fmtHM(result.hours_this_block)}</span></>
          )}
        </div>
      </div>
    );
  }

  // PIN pad view when a person is selected
  if (selected) {
    return (
      <div className="max-w-sm mx-auto">
        <div className="rounded-2xl border border-slate-200 bg-white shadow-sm p-6">
          <div className="text-center mb-4">
            <div className="text-xs uppercase tracking-wide text-slate-500">
              {selected.is_clocked_in ? "Currently clocked in" : "Ready to clock in"}
            </div>
            <div className="text-2xl font-semibold text-slate-900 mt-1">
              {selected.first_name} {selected.last_name}
            </div>
            <div className="text-xs text-slate-500 mt-1">Enter your 4-digit PIN</div>
          </div>

          <div className="flex justify-center gap-3 mb-5">
            {[0, 1, 2, 3].map((i) => (
              <div
                key={i}
                className={`w-4 h-4 rounded-full border-2 ${
                  pin.length > i ? "bg-slate-900 border-slate-900" : "border-slate-300"
                }`}
              />
            ))}
          </div>

          {result?.ok === false && (
            <div className="mb-3 text-center text-sm text-rose-600">
              {result.error === "invalid_pin" && "Wrong PIN. Try again."}
              {result.error === "pin_not_set" && "PIN not set. See Peter."}
              {result.error === "inactive_staff" && "Account inactive."}
              {result.error === "not_hourly" && "Not an hourly position."}
              {!["invalid_pin", "pin_not_set", "inactive_staff", "not_hourly"].includes(result.error)
                && (result.message || "Something went wrong.")}
            </div>
          )}

          <div className="grid grid-cols-3 gap-2">
            {["1", "2", "3", "4", "5", "6", "7", "8", "9"].map((d) => (
              <button
                key={d}
                onClick={() => appendDigit(d)}
                disabled={busy}
                className="h-14 rounded-lg bg-slate-100 hover:bg-slate-200 active:bg-slate-300 text-xl font-medium text-slate-800 disabled:opacity-40"
              >
                {d}
              </button>
            ))}
            <button
              onClick={cancel}
              disabled={busy}
              className="h-14 rounded-lg bg-white border border-slate-200 hover:bg-slate-50 text-sm text-slate-600 disabled:opacity-40"
            >
              Cancel
            </button>
            <button
              onClick={() => appendDigit("0")}
              disabled={busy}
              className="h-14 rounded-lg bg-slate-100 hover:bg-slate-200 active:bg-slate-300 text-xl font-medium text-slate-800 disabled:opacity-40"
            >
              0
            </button>
            <button
              onClick={backspace}
              disabled={busy || pin.length === 0}
              className="h-14 rounded-lg bg-white border border-slate-200 hover:bg-slate-50 text-sm text-slate-600 disabled:opacity-40"
            >
              ⌫
            </button>
          </div>
        </div>
      </div>
    );
  }

  // Tile grid (default kiosk landing)
  return (
    <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
      {(staff || []).map((s) => (
        <button
          key={s.staff_id}
          onClick={() => pickStaff(s)}
          className={`rounded-xl border p-5 text-left transition shadow-sm hover:shadow ${
            s.is_clocked_in
              ? "bg-emerald-50 border-emerald-200"
              : "bg-white border-slate-200 hover:border-slate-300"
          }`}
        >
          <div className="flex items-start justify-between">
            <div>
              <div className="text-lg font-semibold text-slate-900">
                {s.first_name} {s.last_name}
              </div>
              <div className="text-xs text-slate-500 mt-0.5">${Number(s.pay_rate).toFixed(2)}/hr</div>
            </div>
            {s.is_clocked_in ? (
              <span className="inline-flex items-center gap-1 rounded-full bg-emerald-100 text-emerald-800 text-xs px-2 py-0.5">
                <span className="w-1.5 h-1.5 rounded-full bg-emerald-500 animate-pulse" />
                On the clock
              </span>
            ) : (
              <span className="inline-flex items-center rounded-full bg-slate-100 text-slate-600 text-xs px-2 py-0.5">
                Off
              </span>
            )}
          </div>
          <div className="mt-4 text-sm">
            {s.is_clocked_in ? (
              <span className="text-slate-700">
                In since <span className="font-medium">{fmtTime(s.clock_in_at)}</span> ·{" "}
                <span className="font-medium">{fmtHM(s.hours_this_block)}</span> this block
              </span>
            ) : (
              <span className="text-slate-500">Tap to clock in</span>
            )}
          </div>
          {!s.pin_set && (
            <div className="mt-3 text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded px-2 py-1">
              PIN not set — see Peter
            </div>
          )}
        </button>
      ))}
    </div>
  );
}

// =====================================================================
// ADMIN VIEW — weekly timesheet, edit, set PIN
// =====================================================================
function AdminView({ userId }) {
  const { staff, loading: staffLoading, reload: reloadStaff } = useHourlyStaff();
  const [weekStart, setWeekStart] = useState(() => startOfSundayWeek(new Date()));
  const [entries, setEntries] = useState([]);
  const [entriesLoading, setEntriesLoading] = useState(true);
  const [editingEntry, setEditingEntry] = useState(null);
  const [settingPinFor, setSettingPinFor] = useState(null);
  const [creatingFor, setCreatingFor] = useState(null);

  const weekEnd = useMemo(() => endOfSaturdayWeek(weekStart), [weekStart]);

  const loadEntries = useCallback(async () => {
    setEntriesLoading(true);
    const { data, error } = await supabase
      .from("time_clock_entries")
      .select("*")
      .eq("agency_id", AGENCY_ID)
      .gte("clock_in_at", weekStart.toISOString())
      .lt("clock_in_at", weekEnd.toISOString())
      .order("clock_in_at", { ascending: true });
    if (!error) setEntries(data || []);
    setEntriesLoading(false);
  }, [weekStart, weekEnd]);

  useEffect(() => { loadEntries(); }, [loadEntries]);

  // group entries by staff_id, then by day-of-week
  const byStaff = useMemo(() => {
    const map = new Map();
    for (const s of staff || []) {
      map.set(s.staff_id, { staff: s, days: Array.from({ length: 7 }, () => []) });
    }
    for (const e of entries || []) {
      const bucket = map.get(e.staff_id);
      if (!bucket) continue;
      const dayIdx = (new Date(e.clock_in_at).getDay()); // 0 = Sun
      bucket.days[dayIdx].push(e);
    }
    return map;
  }, [staff, entries]);

  function shiftWeek(deltaWeeks) {
    setWeekStart((cur) => addDays(cur, deltaWeeks * 7));
  }
  function jumpToThisWeek() {
    setWeekStart(startOfSundayWeek(new Date()));
  }

  const weekLabel = `${weekStart.toLocaleDateString([], { month: "short", day: "numeric" })} – ${addDays(weekEnd, -1).toLocaleDateString([], { month: "short", day: "numeric", year: "numeric" })}`;
  const thisWeekStart = startOfSundayWeek(new Date());
  const isThisWeek = weekStart.getTime() === thisWeekStart.getTime();

  return (
    <div className="space-y-6">
      {/* Live status strip */}
      <div className="rounded-xl border border-slate-200 bg-white p-4">
        <div className="text-xs uppercase tracking-wide text-slate-500 mb-2">On the clock right now</div>
        {staffLoading ? (
          <div className="text-sm text-slate-500">Loading…</div>
        ) : (
          <div className="flex flex-wrap gap-2">
            {(staff || []).filter((s) => s.is_clocked_in).length === 0 ? (
              <span className="text-sm text-slate-500">Nobody is clocked in.</span>
            ) : (
              (staff || [])
                .filter((s) => s.is_clocked_in)
                .map((s) => (
                  <div key={s.staff_id} className="inline-flex items-center gap-2 rounded-full bg-emerald-50 border border-emerald-200 px-3 py-1 text-sm">
                    <span className="w-2 h-2 rounded-full bg-emerald-500 animate-pulse" />
                    <span className="font-medium text-emerald-900">{s.first_name} {s.last_name}</span>
                    <span className="text-emerald-700">
                      since {fmtTime(s.clock_in_at)} · {fmtHM(s.hours_this_block)}
                    </span>
                  </div>
                ))
            )}
          </div>
        )}
      </div>

      {/* Week navigator */}
      <div className="flex items-center gap-2 flex-wrap">
        <button onClick={() => shiftWeek(-1)} className="px-3 py-1.5 rounded-md border border-slate-200 hover:bg-slate-50 text-sm">← Prev</button>
        <div className="px-3 py-1.5 rounded-md bg-slate-100 text-sm font-medium text-slate-800">
          {weekLabel}
        </div>
        <button onClick={() => shiftWeek(1)} className="px-3 py-1.5 rounded-md border border-slate-200 hover:bg-slate-50 text-sm">Next →</button>
        {!isThisWeek && (
          <button onClick={jumpToThisWeek} className="px-3 py-1.5 rounded-md text-sm text-sky-700 hover:bg-sky-50">This week</button>
        )}
      </div>

      {/* Per-employee timesheets */}
      {entriesLoading ? (
        <div className="text-sm text-slate-500">Loading entries…</div>
      ) : (
        <div className="space-y-4">
          {Array.from(byStaff.values()).map(({ staff: s, days }) => (
            <EmployeeWeekCard
              key={s.staff_id}
              staff={s}
              days={days}
              weekStart={weekStart}
              onEdit={(e) => setEditingEntry(e)}
              onCreate={() => setCreatingFor(s)}
              onSetPin={() => setSettingPinFor(s)}
            />
          ))}
        </div>
      )}

      {/* Modals */}
      {editingEntry && (
        <EditEntryModal
          entry={editingEntry}
          userId={userId}
          onClose={() => setEditingEntry(null)}
          onSaved={() => { setEditingEntry(null); loadEntries(); reloadStaff(); }}
        />
      )}
      {creatingFor && (
        <CreateEntryModal
          staff={creatingFor}
          userId={userId}
          onClose={() => setCreatingFor(null)}
          onSaved={() => { setCreatingFor(null); loadEntries(); reloadStaff(); }}
        />
      )}
      {settingPinFor && (
        <SetPinModal
          staff={settingPinFor}
          onClose={() => setSettingPinFor(null)}
          onSaved={() => { setSettingPinFor(null); reloadStaff(); }}
        />
      )}
    </div>
  );
}

function EmployeeWeekCard({ staff: s, days, weekStart, onEdit, onCreate, onSetPin }) {
  const totalHours = useMemo(() => {
    let h = 0;
    for (const dayEntries of days) {
      for (const e of dayEntries) {
        if (e.clock_out_at) h += hoursBetween(e.clock_in_at, e.clock_out_at);
      }
    }
    return h;
  }, [days]);
  const grossPay = totalHours * Number(s.pay_rate || 0);
  const overtimeFlag = totalHours > 40;

  return (
    <div className="rounded-xl border border-slate-200 bg-white shadow-sm overflow-hidden">
      <div className="flex items-center justify-between p-4 bg-slate-50 border-b border-slate-200 flex-wrap gap-2">
        <div>
          <div className="text-base font-semibold text-slate-900">
            {s.first_name} {s.last_name}
          </div>
          <div className="text-xs text-slate-500 mt-0.5">
            ${Number(s.pay_rate).toFixed(2)}/hr · {s.pin_set ? "PIN set" : <span className="text-amber-700">PIN not set</span>}
          </div>
        </div>
        <div className="flex items-center gap-3 flex-wrap">
          <div className="text-right">
            <div className="text-xs text-slate-500">Week total</div>
            <div className={`text-base font-semibold ${overtimeFlag ? "text-amber-700" : "text-slate-900"}`}>
              {fmtHM(totalHours)}{overtimeFlag && " ⚠"}
            </div>
            <div className="text-xs text-slate-600">${grossPay.toFixed(2)} gross</div>
          </div>
          <button onClick={onCreate} className="px-2.5 py-1 rounded text-xs border border-slate-200 hover:bg-white">+ Entry</button>
          <button onClick={onSetPin} className="px-2.5 py-1 rounded text-xs border border-slate-200 hover:bg-white">Set PIN</button>
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-7 divide-y md:divide-y-0 md:divide-x divide-slate-100">
        {days.map((dayEntries, i) => {
          const dayDate = addDays(weekStart, i);
          const dayHours = dayEntries.reduce(
            (acc, e) => acc + (e.clock_out_at ? hoursBetween(e.clock_in_at, e.clock_out_at) : 0),
            0
          );
          return (
            <div key={i} className="p-3 min-h-[110px]">
              <div className="flex items-baseline justify-between mb-1.5">
                <div className="text-xs font-medium text-slate-700">
                  {["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][i]}{" "}
                  <span className="text-slate-400">{dayDate.getMonth() + 1}/{dayDate.getDate()}</span>
                </div>
                {dayHours > 0 && (
                  <div className="text-xs font-medium text-slate-600">{fmtHM(dayHours)}</div>
                )}
              </div>
              <div className="space-y-1">
                {dayEntries.length === 0 ? (
                  <div className="text-xs text-slate-300">—</div>
                ) : (
                  dayEntries.map((e) => (
                    <button
                      key={e.id}
                      onClick={() => onEdit(e)}
                      className={`w-full text-left text-xs rounded px-2 py-1 ${
                        e.clock_out_at
                          ? "bg-slate-50 hover:bg-slate-100 border border-slate-200"
                          : "bg-emerald-50 hover:bg-emerald-100 border border-emerald-200"
                      }`}
                    >
                      <div className="font-medium text-slate-800">
                        {fmtTime(e.clock_in_at)} – {e.clock_out_at ? fmtTime(e.clock_out_at) : <span className="text-emerald-700">on now</span>}
                      </div>
                      {e.clock_out_at && (
                        <div className="text-slate-500">{fmtHM(hoursBetween(e.clock_in_at, e.clock_out_at))}</div>
                      )}
                      {e?.source && e.source !== "kiosk" && (
                        <div className="text-[10px] uppercase tracking-wide text-slate-400 mt-0.5">{e.source.replace("_", " ")}</div>
                      )}
                    </button>
                  ))
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// =====================================================================
// EDIT / CREATE / PIN modals
// =====================================================================
function EditEntryModal({ entry, userId, onClose, onSaved }) {
  const [inAt, setInAt] = useState(toLocalInputValue(entry.clock_in_at));
  const [outAt, setOutAt] = useState(entry.clock_out_at ? toLocalInputValue(entry.clock_out_at) : "");
  const [notes, setNotes] = useState(entry.notes || "");
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState(null);

  async function save() {
    setSaving(true); setErr(null);
    const payload = {
      clock_in_at: new Date(inAt).toISOString(),
      clock_out_at: outAt ? new Date(outAt).toISOString() : null,
      notes: notes || null,
      source: "admin_edit",
      edited_by_user_id: userId || null,
      edited_at: new Date().toISOString(),
    };
    const { error } = await supabase.from("time_clock_entries").update(payload).eq("id", entry.id);
    setSaving(false);
    if (error) { setErr(error.message); return; }
    onSaved?.();
  }
  async function del() {
    if (!confirm("Delete this entry? This cannot be undone.")) return;
    setSaving(true); setErr(null);
    const { error } = await supabase.from("time_clock_entries").delete().eq("id", entry.id);
    setSaving(false);
    if (error) { setErr(error.message); return; }
    onSaved?.();
  }

  return (
    <ModalShell title="Edit time entry" onClose={onClose}>
      <div className="space-y-3">
        <Field label="Clock in"><input type="datetime-local" value={inAt} onChange={(e) => setInAt(e.target.value)} className="w-full rounded border border-slate-200 px-2 py-1.5 text-sm" /></Field>
        <Field label="Clock out (blank = still on the clock)">
          <input type="datetime-local" value={outAt} onChange={(e) => setOutAt(e.target.value)} className="w-full rounded border border-slate-200 px-2 py-1.5 text-sm" />
        </Field>
        <Field label="Notes">
          <textarea value={notes} onChange={(e) => setNotes(e.target.value)} rows={2} className="w-full rounded border border-slate-200 px-2 py-1.5 text-sm" />
        </Field>
        {err && <div className="text-sm text-rose-600">{err}</div>}
        <div className="flex items-center justify-between pt-2">
          <button onClick={del} disabled={saving} className="px-3 py-1.5 text-sm text-rose-700 hover:bg-rose-50 rounded">Delete</button>
          <div className="flex gap-2">
            <button onClick={onClose} disabled={saving} className="px-3 py-1.5 text-sm border border-slate-200 rounded hover:bg-slate-50">Cancel</button>
            <button onClick={save} disabled={saving} className="px-3 py-1.5 text-sm bg-slate-900 text-white rounded hover:bg-slate-800">{saving ? "Saving…" : "Save"}</button>
          </div>
        </div>
      </div>
    </ModalShell>
  );
}

function CreateEntryModal({ staff: s, userId, onClose, onSaved }) {
  const defaultDay = (() => {
    const d = new Date();
    const pad = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  })();
  const [inAt, setInAt] = useState(`${defaultDay}T09:00`);
  const [outAt, setOutAt] = useState(`${defaultDay}T17:00`);
  const [notes, setNotes] = useState("");
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState(null);

  async function save() {
    setSaving(true); setErr(null);
    const payload = {
      agency_id: AGENCY_ID,
      staff_id: s.staff_id,
      clock_in_at: new Date(inAt).toISOString(),
      clock_out_at: outAt ? new Date(outAt).toISOString() : null,
      notes: notes || null,
      source: "admin_create",
      edited_by_user_id: userId || null,
      edited_at: new Date().toISOString(),
    };
    const { error } = await supabase.from("time_clock_entries").insert(payload);
    setSaving(false);
    if (error) { setErr(error.message); return; }
    onSaved?.();
  }

  return (
    <ModalShell title={`Add entry for ${s.first_name}`} onClose={onClose}>
      <div className="space-y-3">
        <Field label="Clock in"><input type="datetime-local" value={inAt} onChange={(e) => setInAt(e.target.value)} className="w-full rounded border border-slate-200 px-2 py-1.5 text-sm" /></Field>
        <Field label="Clock out (blank = still on the clock)">
          <input type="datetime-local" value={outAt} onChange={(e) => setOutAt(e.target.value)} className="w-full rounded border border-slate-200 px-2 py-1.5 text-sm" />
        </Field>
        <Field label="Notes">
          <textarea value={notes} onChange={(e) => setNotes(e.target.value)} rows={2} className="w-full rounded border border-slate-200 px-2 py-1.5 text-sm" />
        </Field>
        {err && <div className="text-sm text-rose-600">{err}</div>}
        <div className="flex justify-end gap-2 pt-2">
          <button onClick={onClose} disabled={saving} className="px-3 py-1.5 text-sm border border-slate-200 rounded hover:bg-slate-50">Cancel</button>
          <button onClick={save} disabled={saving} className="px-3 py-1.5 text-sm bg-slate-900 text-white rounded hover:bg-slate-800">{saving ? "Saving…" : "Add entry"}</button>
        </div>
      </div>
    </ModalShell>
  );
}

function SetPinModal({ staff: s, onClose, onSaved }) {
  const [pin, setPin] = useState("");
  const [confirm, setConfirm] = useState("");
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState(null);

  async function save() {
    setErr(null);
    if (!/^\d{4}$/.test(pin)) { setErr("PIN must be exactly 4 digits."); return; }
    if (pin !== confirm) { setErr("PINs don't match."); return; }
    setSaving(true);
    const { data, error } = await supabase.rpc("time_clock_set_pin", {
      p_staff_id: s.staff_id,
      p_pin: pin,
    });
    setSaving(false);
    if (error) { setErr(error.message); return; }
    if (data?.ok === false) { setErr(data.error); return; }
    onSaved?.();
  }

  return (
    <ModalShell title={`${s.pin_set ? "Reset" : "Set"} PIN for ${s.first_name}`} onClose={onClose}>
      <div className="space-y-3">
        <div className="text-sm text-slate-600">
          Pick a 4-digit PIN. Share it with {s.first_name} privately. She'll enter it at the kiosk to clock in/out.
        </div>
        <Field label="New 4-digit PIN">
          <input type="password" inputMode="numeric" maxLength={4} value={pin}
            onChange={(e) => setPin(e.target.value.replace(/\D/g, "").slice(0, 4))}
            className="w-full rounded border border-slate-200 px-2 py-1.5 text-sm tracking-widest" />
        </Field>
        <Field label="Confirm PIN">
          <input type="password" inputMode="numeric" maxLength={4} value={confirm}
            onChange={(e) => setConfirm(e.target.value.replace(/\D/g, "").slice(0, 4))}
            className="w-full rounded border border-slate-200 px-2 py-1.5 text-sm tracking-widest" />
        </Field>
        {err && <div className="text-sm text-rose-600">{err}</div>}
        <div className="flex justify-end gap-2 pt-2">
          <button onClick={onClose} disabled={saving} className="px-3 py-1.5 text-sm border border-slate-200 rounded hover:bg-slate-50">Cancel</button>
          <button onClick={save} disabled={saving} className="px-3 py-1.5 text-sm bg-slate-900 text-white rounded hover:bg-slate-800">{saving ? "Saving…" : "Save PIN"}</button>
        </div>
      </div>
    </ModalShell>
  );
}

// =====================================================================
// Shared bits
// =====================================================================
function ModalShell({ title, onClose, children }) {
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 p-4" onClick={onClose}>
      <div className="bg-white rounded-xl shadow-xl w-full max-w-md p-5" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between mb-3">
          <div className="font-semibold text-slate-900">{title}</div>
          <button onClick={onClose} className="text-slate-400 hover:text-slate-600 text-lg leading-none">×</button>
        </div>
        {children}
      </div>
    </div>
  );
}
function Field({ label, children }) {
  return (
    <label className="block">
      <div className="text-xs font-medium text-slate-600 mb-1">{label}</div>
      {children}
    </label>
  );
}
function toLocalInputValue(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  const pad = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
