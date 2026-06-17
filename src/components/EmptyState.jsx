import { useState } from "react";

import { T } from "../lib/theme.js";

/**
 * EmptyState — shown when a table has 0 rows
 * Tells Dominique exactly what's missing and how to add it
 * Never shows fake/mock data
 */
export default function EmptyState({
  icon = "ð",
  title,
  description,
  ctaText,
  ctaHref,
  onCtaClick,
  module,
  awaiting = false,
}) {
  const moduleDefaults = {
    tasks:        { icon: "✅", title: "No tasks yet",           desc: "Add your first task by telling your Claude: \"Add a task: [title], due [date], priority [high/medium/low]\"" },
    goals:        { icon: "ð¯", title: "No goals set",           desc: "Tell your Claude: \"Add a goal: [title], target date [date], category [financial/growth/compliance]\"" },
    social:       { icon: "ð±", title: "No posts scheduled",     desc: "Your content calendar is empty. Ask your Claude to schedule posts or use the BCC Media Studio." },
    compliance:   { icon: "⚖️", title: "Compliance rules pending", desc: "Your 57 State Farm compliance rules need to be seeded. Ask your Claude: \"Seed my compliance rules from migration 002.\"" },
    documents:    { icon: "ð", title: "No documents yet",       desc: "Documents you process through your BCC will appear here." },
    alerts:       { icon: "ð", title: "All clear",              desc: "No active alerts. Your BCC will surface issues here when they need your attention." },
    automations:  { icon: "⚡", title: "No automations running", desc: "Your Rube.app recipes appear here once connected. Ask your Claude to check recipe status." },
    performance:  { icon: "ð", title: "No performance data yet", desc: "Monthly performance logs will appear here once your first review cycle runs." },
    applicants:   { icon: "ð¤", title: "No applicants",          desc: "Open positions and applicants will appear here when you start hiring." },
    aipp:         { icon: "ð", title: "AIPP data pending",      desc: "Your AIPP tracking will populate once your annual target is set. Tell your Claude: \"Set my 2026 AIPP target: $[amount]\"" },
    scorecard:   { icon: "ð¥", title: "Scorecard pending",     desc: "Monthly ScoreCard Bonus data will appear here. Ask your Claude to load your current Scorecard metrics." },
    memory:       { icon: "ð§ ", title: "No memory entries",      desc: "Your BCC builds persistent memory from your conversations over time." },
  };

  const defaults = module ? (moduleDefaults[module] || {}) : {};
  const displayIcon = icon || defaults.icon || "ð";
  const displayTitle = title || defaults.title || "No data yet";
  const displayDesc = description || defaults.desc || "This section will populate as you use your BCC.";

  return (
    <div style={{
      display: "flex", flexDirection: "column", alignItems: "center",
      justifyContent: "center", padding: "40px 24px", textAlign: "center",
      minHeight: 200,
    }}>
      {awaiting && (
        <div style={{
          display: "inline-flex", alignItems: "center", gap: 6,
          background: T.amberLt, color: T.slate700, borderRadius: 20,
          padding: "4px 12px", fontSize: 11, fontWeight: 600,
          marginBottom: 16, border: "1px solid #FDE68A"
        }}>
          ⏳ Awaiting Information
        </div>
      )}

      <div style={{ fontSize: 36, marginBottom: 12 }}>{displayIcon}</div>

      <div style={{
        fontSize: 15, fontWeight: 600, color: T.slate900, marginBottom: 8
      }}>
        {displayTitle}
      </div>

      <div style={{
        fontSize: 12, color: T.slate500, maxWidth: 320, lineHeight: 1.6, marginBottom: 20
      }}>
        {displayDesc}
      </div>

      {(ctaText || onCtaClick) && (
        <button
          onClick={onCtaClick}
          style={{
            padding: "8px 20px", fontSize: 12, fontWeight: 600,
            background: T.blue, color: "white", border: "none",
            borderRadius: 6, cursor: "pointer"
          }}
        >
          {ctaText || "Add Data"}
        </button>
      )}
    </div>
  );
}
