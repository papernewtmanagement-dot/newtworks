import { createContext, useContext } from "react";
import { T } from "./theme.js";
import { handleModuleLinkClick } from "./routing.jsx";

// A customer's name is a link everywhere it shows on the Dashboard. Clicking it
// opens that household's whole account (Peter 2026-09-18).
//
// The popup itself is rendered once, by the Dashboard shell, off the ?acct=
// query parameter. That is what makes right-click "Open in new tab" work and
// what keeps the popup open through a refresh. Any tab, including one that
// lives in its own file, only has to use <CustomerName> — nothing is passed
// down through props.
//
// The household key is the name plus the last four digits of the phone, the
// same key the log itself uses. Records logged before the phone rule have no
// phone; they match any phone, so they still turn up.

export const AccountCtx = createContext(null);

export const acctToken = (label, phone4) =>
  `${String(label || "").trim()}|${String(phone4 || "").trim()}`;

export function parseAcctToken(tok) {
  const s = String(tok || "");
  const i = s.lastIndexOf("|");
  if (i < 0) return { label: s.trim(), phone4: "" };
  return { label: s.slice(0, i).trim(), phone4: s.slice(i + 1).trim() };
}

export function CustomerName({ label, phone4, style, empty = "—" }) {
  const ctx = useContext(AccountCtx);
  const name = String(label || "").trim();
  if (!name) return <span style={style}>{empty}</span>;
  if (!ctx) return <span style={style}>{name}</span>;
  const tok = acctToken(name, phone4);
  return (
    <a
      href={ctx.hrefFor(tok)}
      title={`Everything on file for ${name}`}
      onClick={(e) => handleModuleLinkClick(e, () => ctx.open(tok))}
      style={{ color: T.blue, textDecoration: "none", fontWeight: 600, cursor: "pointer", ...style }}
    >
      {name}
    </a>
  );
}
