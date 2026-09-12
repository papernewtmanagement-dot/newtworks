import { useState, useEffect } from "react";
import { supabase } from "../lib/supabase.js";
import TimeClock from "./TimeClock.jsx";
import TimeOffRequests from "./TimeOffRequests.jsx";

import { useTabParam, TabLink } from "../lib/routing.jsx";
// ─────────────────────────────────────────────────────────────────────────────
// TimeHub: parent module that unifies Timeclock and Time Off & Remote under a
// single nav entry with a top-level tab switch.
//
// Outer tabs are styled slightly heavier than the inner sub-tabs each child
// module renders (TimeOffRequests has its own Submit / Vote / My Requests /
// Inbox strip), so the visual hierarchy reads as primary section → secondary
// filter and a user is not confused between the two.
// ─────────────────────────────────────────────────────────────────────────────

const TABS = [
  { id: "timeclock", label: "Time Clock" },
  { id: "timeoff",   label: "Time Off" }
];

export default function TimeHub({ embedded = false }) {
  // Param is "hours", not "tab": this now renders inside the Dashboard, whose
  // own tab bar owns ?tab=. Two tab groups may never share a param name.
  const [activeTab, setActiveTab, tabHref] = useTabParam("hours", "timeclock", ["timeclock","timeoff"]);
  // The time clock is for hourly people. Salaried teammates never see it
  // (Peter 2026-09-12) — they still get Time Off. my_pay_type returns only
  // the viewer's own pay type, so nothing else about pay is exposed here.
  const [payType, setPayType] = useState(null);
  useEffect(() => {
    let alive = true;
    supabase.rpc("my_pay_type").then(r => { if (alive) setPayType(r?.data || ""); });
    return () => { alive = false; };
  }, []);
  const salaried = String(payType || "").toUpperCase() === "SALARY";
  const visibleTabs = salaried ? TABS.filter(t => t.id !== "timeclock") : TABS;
  const shownTab = salaried && activeTab === "timeclock" ? "timeoff" : activeTab;

  return (
    <div>
      <div style={{ borderBottom: "1px solid #e2e8f0", background: "#fff", marginTop: embedded ? -8 : 0 }}>
        <div style={{
          maxWidth: 1200,
          margin: "0 auto",
          padding: "8px 12px 0",
          display: "flex",
          gap: 4
        }}>
          {visibleTabs.map(tab => (
            <TabLink
              key={tab.id}
              href={tabHref(tab.id)}
              onSelect={() => setActiveTab(tab.id)}
              style={{
                padding: "10px 18px",
                border: "none",
                borderBottom: shownTab === tab.id ? "3px solid #0f172a" : "3px solid transparent",
                background: "transparent",
                cursor: "pointer",
                fontSize: 15,
                fontWeight: shownTab === tab.id ? 600 : 500,
                color: shownTab === tab.id ? "#0f172a" : "#64748b",
                marginBottom: -1
              }}
            >
              {tab.label}
            </TabLink>
          ))}
        </div>
      </div>
      <div>
        {shownTab === "timeclock" && !salaried && <TimeClock />}
        {shownTab === "timeoff" && <TimeOffRequests />}
      </div>
    </div>
  );
}
