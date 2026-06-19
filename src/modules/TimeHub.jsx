import { useState } from "react";
import TimeClock from "./TimeClock.jsx";
import TimeOffRequests from "./TimeOffRequests.jsx";

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

export default function TimeHub() {
  const [activeTab, setActiveTab] = useState("timeclock");

  return (
    <div>
      <div style={{ borderBottom: "1px solid #e2e8f0", background: "#fff" }}>
        <div style={{
          maxWidth: 1200,
          margin: "0 auto",
          padding: "12px 24px 0",
          display: "flex",
          gap: 4
        }}>
          {TABS.map(tab => (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id)}
              style={{
                padding: "10px 18px",
                border: "none",
                borderBottom: activeTab === tab.id ? "3px solid #0f172a" : "3px solid transparent",
                background: "transparent",
                cursor: "pointer",
                fontSize: 15,
                fontWeight: activeTab === tab.id ? 600 : 500,
                color: activeTab === tab.id ? "#0f172a" : "#64748b",
                marginBottom: -1
              }}
            >
              {tab.label}
            </button>
          ))}
        </div>
      </div>
      <div>
        {activeTab === "timeclock" && <TimeClock />}
        {activeTab === "timeoff" && <TimeOffRequests />}
      </div>
    </div>
  );
}
