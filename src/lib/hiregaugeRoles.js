// Display names for the seven canonical HireGauge roles. Shared by the
// candidate page (Results matrix, Assessment layer, Competencies) and the CTS
// Sales Profile panel so the names can never drift apart. Moved out of
// src/components/CandidateDetail.jsx on 2026-09-26 when the CTS panel started
// showing a fit per role; the labels themselves are unchanged.
export const ROLE_LABELS = {
  sales_outbound:       "Sales - Outbound",
  sales_inbound:        "Sales - Inbound",
  sales_in_book:        "Sales - In-Book",
  retention_reception:  "Retention - Reception",
  retention_escalation: "Retention - Escalation",
  retention_support:    "Retention - Support",
  aspirant:             "Aspirant",
};
