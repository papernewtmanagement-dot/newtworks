# Business Command Center — Master Template

Built by **Imaginary Farms LLC** · The Claude Whisperer · [imaginary-farms.com](https://imaginary-farms.com)

---

## What This Is

The BCC (Business Command Center) is a full-stack React web application built exclusively for State Farm agents. It connects to Supabase (database), Composio (automations), Claude.ai (intelligence layer), GitHub (code), and Vercel (hosting) to give agents a complete AI-powered operating system for their business.

This repository is the **master template**. Each client install creates a fork of this repo. **The fork is the client's app from that point forward** — the master never pushes updates back to client forks. New clients always start from the latest master at fork time.

## Stack

- **Frontend:** React + Vite
- **Hosting:** Vercel (client's own account)
- **Database:** Supabase (client's own project)
- **Automations:** Composio (client's own account)
- **Intelligence:** Claude.ai (client's own subscription)

## Repository Structure

```
bcc-master-template/
├── BCCApp.jsx                    # App shell, nav, dashboard, routing
├── src/
│   ├── main.jsx                  # React entry point
│   ├── components/
│   │   └── ErrorBoundary.jsx     # Per-module error boundary (catches runtime errors gracefully)
│   ├── lib/
│   │   ├── supabase.js
│   │   ├── hooks.js              # useSupabaseTable, etc.
│   │   └── utils.js              # fmt, pct, fmtDate, safeArr, safeNum
│   └── modules/
│       ├── Dashboard.jsx         # 7 widgets, AIPP, monthly close, KPIs
│       ├── Financials.jsx        # P&L, Comp Recap, AIPP, Payroll, Bank, Credit, GL
│       ├── PersistentMemory.jsx
│       ├── ComplianceCenter.jsx
│       ├── Automations.jsx
│       ├── SocialMedia.jsx
│       ├── TasksGoals.jsx
│       ├── AlertsNotifications.jsx
│       ├── Documents.jsx
│       ├── HRPeople.jsx          # Includes Producer ROI projection (Performance tab)
│       └── Settings.jsx          # Includes self-heal Keep It Connected guide (About tab)
├── supabase/
│   ├── migrations/
│   │   ├── 001_bcc_master_schema.sql           # 37 core tables
│   │   ├── 002_seed_compliance_rules.sql       # 57 SF compliance rules
│   │   ├── 003_seed_chart_of_accounts.sql      # Standard COA
│   │   ├── 004_seed_agency_record.sql          # Agency placeholder
│   │   ├── 005_anon_read_policies.sql          # Anon RLS — REQUIRED
│   │   ├── 006_derived_financial_views.sql     # v_income_statement, v_balance_sheet
│   │   ├── 007_monthly_close_checklist.sql     # Monthly close infrastructure
│   │   ├── 008_bridge_generator.sql            # Path A only — bcc_generate_bridges()
│   │   └── 010_producer_roi_infrastructure.sql # Producer ROI feature — both paths
│   └── demo/
│       └── demo_reset_function.sql             # Sunshine State demo data refresh
├── tools/
│   ├── README.md
│   ├── schema-audit.js                         # Pre-build schema audit (runs on Vercel)
│   └── schema_audit_query.sql                  # Path A diagnostic query (was 007_schema_audit.sql)
├── docs/
│   ├── PRODUCER_ROI_INSTALL.md                 # Performance tab onboarding playbook
│   └── SELF_HEAL_GUIDE.md                      # The "ask your Claude first" model
├── CLAUDE.md                                   # Read-this-first briefing
├── HANDOFF_PROMPTS.md                          # Project Claude install prompts (Path A and B)
├── SCHEMA_NORMALIZATION_RUNBOOK.md             # Path A bridge view runbook
├── index.html
├── package.json
└── vite.config.js
```

## Two Install Paths

| Path | When | Time |
|---|---|---|
| **A — Existing Database** | Client already has a Supabase populated with data | 1-3 hours |
| **B — Clean Install** | Client's Supabase is brand new and empty | 1-2 hours |

See `HANDOFF_PROMPTS.md` for the canonical handoff prompts each Project Claude receives.

## Featured Modules

- **Dashboard** — 7 widgets spanning AIPP progress, monthly close, financials, compliance, alerts
- **Financials** — full bookkeeping view: P&L, Comp Recap (SF detail), AIPP/ScoreBoard, Payroll, Bank, Credit, General Ledger
- **HR & People → Performance** — **Producer ROI projection.** Per-producer 24-month commission trajectory chart with cohort-based renewal projection, lapse rate calculator from comp_recap, breakeven month detection. Built specifically for the State Farm agent decision: "When does this producer start covering their fully-loaded payroll cost?"
- **Settings → About → Keep It Connected** — Self-heal guide that teaches the agent to work *with* their Claude (screenshot the error, paste it, get fixed) rather than navigating dashboards directly.

## Deployment

See `HANDOFF_PROMPTS.md` for the complete install playbook. Each install produces a Vercel deployment connected to the client's own Supabase, Composio, and Claude.ai accounts.

## Hard rules

- **The master never pushes updates to client forks.** Once forked, a client's repo is theirs to evolve with their Claude.
- **The schema is the contract.** The web app code stays canonical; client databases conform via bridge views (Path A) or fresh migrations (Path B).
- **Imports must be line 1** of every `.jsx` file (Vite drops modules silently if any comment precedes imports).
- **`VITE_USE_MOCK_DATA=false` in production.** Mock data is for demos only. Live deployments show real data or `EmptyState` components.
- **One commit at a time during install.** Push, confirm Vercel READY, then push next.
