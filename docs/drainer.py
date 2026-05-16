# =========================================================================
# docs/drainer.py — LLM Parse Queue Drainer (v1.1)
# =========================================================================
# Workbench-side script that drains llm_parse_queue using invoke_llm().
#
# HOW TO USE in a Claude session:
#   1. Open COMPOSIO_REMOTE_WORKBENCH
#   2. Paste this whole file
#   3. Call: drain_llm_queue()  -- drains up to 10
#      Or:   drain_llm_queue_until_empty()  -- drains everything
#
# Behavior:
#   - Atomic claim (FOR UPDATE SKIP LOCKED) -- safe to run concurrently
#   - 3 attempts max per row; failures become high-priority tasks
#   - parse_bank_statement: runs full downstream (classify -> JE -> suspense)
#   - suspense_guesses: stores result_json for UI to consume
#
# See docs/drainer.md for full description.
# =========================================================================

import json
import re
from typing import Any

AGENCY_ID = "126794dd-25ff-47d2-a436-724499733365"
SUPABASE_REF = "vulhdujhbwvibbojiimi"
MAX_ATTEMPTS = 3
DEFAULT_LIMIT = 10


def _sql(query: str) -> list:
    result, err = run_composio_tool("SUPABASE_BETA_RUN_SQL_QUERY", {
        "ref": SUPABASE_REF, "query": query,
    })
    if err:
        raise RuntimeError(f"supabase sql failed: {err}")
    data = result.get("data") or {}
    rows = data.get("result") or []
    if isinstance(rows, str):
        try: rows = json.loads(rows)
        except: rows = []
    return rows or []


def _sql_escape(s: Any) -> str:
    if s is None: return "NULL"
    if isinstance(s, bool): return "TRUE" if s else "FALSE"
    if isinstance(s, (int, float)): return str(s)
    return "'" + str(s).replace("'", "''") + "'"


def _strip_fences(text: str) -> str:
    return re.sub(r"^```(?:json)?\s*|\s*```$", "", text.strip())


def _claim_pending(agency_id: str, limit: int) -> list[dict]:
    return _sql(f"""
        WITH claimed AS (
          SELECT id FROM llm_parse_queue
          WHERE agency_id = {_sql_escape(agency_id)}
            AND status = 'pending' AND attempts < {MAX_ATTEMPTS}
          ORDER BY created_at LIMIT {limit}
          FOR UPDATE SKIP LOCKED
        )
        UPDATE llm_parse_queue q
        SET status='processing', attempts=attempts+1, last_attempt_at=NOW()
        FROM claimed c WHERE q.id = c.id
        RETURNING q.id, q.agency_id, q.document_id, q.purpose,
                  q.system_prompt, q.user_content, q.model, q.attempts;
    """)


def _mark_succeeded(row_id: str, result_json: Any, raw: str) -> None:
    _sql(f"""
        UPDATE llm_parse_queue
        SET status='succeeded',
            result_json={_sql_escape(json.dumps(result_json))}::jsonb,
            result_raw={_sql_escape(raw[:50000])},
            completed_at=NOW(), last_error=NULL
        WHERE id = {_sql_escape(row_id)};
    """)


def _mark_retry_or_failed(row_id: str, attempts: int, error: str) -> str:
    if attempts >= MAX_ATTEMPTS:
        _sql(f"""
            UPDATE llm_parse_queue
            SET status='failed', last_error={_sql_escape(error[:2000])},
                completed_at=NOW()
            WHERE id = {_sql_escape(row_id)};
        """)
        return "failed"
    _sql(f"""
        UPDATE llm_parse_queue
        SET status='pending', last_error={_sql_escape(error[:2000])}
        WHERE id = {_sql_escape(row_id)};
    """)
    return "pending"


def _create_failure_task(agency_id: str, row: dict, error: str) -> None:
    purpose = row.get("purpose", "?")
    title = f"LLM parse FAILED ({purpose}) -- review needed"
    desc = (
        f"The LLM drainer exhausted {MAX_ATTEMPTS} attempts on llm_parse_queue row {row['id']}.\n\n"
        f"Purpose: {purpose}\nDocument: {row.get('document_id') or '(none)'}\n"
        f"Model: {row.get('model')}\n\nLast error:\n{error[:1500]}\n\n"
        f"Action: review the source, fix the prompt or file, then "
        f"UPDATE llm_parse_queue SET status='pending', attempts=0 WHERE id='{row['id']}'; "
        f"then run drain_llm_queue() again."
    )
    _sql(f"""
        INSERT INTO tasks (agency_id, title, description, created_by, priority, status,
                           module_reference, related_id)
        VALUES (
          {_sql_escape(agency_id)}, {_sql_escape(title)}, {_sql_escape(desc)},
          'llm_drainer', 'high', 'open',
          'automations/llm_queue', {_sql_escape(row['id'])}
        );
    """)


def _resolve_account_id(agency_id: str, code: str) -> str | None:
    rows = _sql(f"""
        SELECT id FROM chart_of_accounts
        WHERE agency_id = {_sql_escape(agency_id)} AND account_code = {_sql_escape(code)}
        LIMIT 1;
    """)
    return rows[0]["id"] if rows else None


def _make_ref(source: str, txn_date: str, amt: float, payee: str) -> str:
    payee_short = re.sub(r"[^a-z0-9]", "", payee.lower())[:20]
    return f"dp:{source}:{txn_date}:{round(abs(amt)*100)}:{payee_short}"


def _classify(agency_id: str, payee: str, memo: str, signed_amt: float, source: str) -> dict:
    direction = "credit" if signed_amt > 0 else "debit"
    rows = _sql(f"""
        SELECT id, rule_name, match_priority, match_payee_regex, match_memo_regex,
               match_source_account, match_amount_min, match_amount_max, match_direction,
               debit_account_code, credit_account_code, sub_category_label, confidence
        FROM gl_classification_rules
        WHERE agency_id = {_sql_escape(agency_id)} AND is_active=true
        ORDER BY match_priority ASC;
    """)
    amt = abs(signed_amt)
    for r in rows:
        if r["match_direction"] not in (direction, "both"): continue
        if r.get("match_payee_regex"):
            try:
                if not re.search(r["match_payee_regex"], payee, re.I): continue
            except: continue
        if r.get("match_memo_regex"):
            try:
                if not re.search(r["match_memo_regex"], memo, re.I): continue
            except: continue
        if r.get("match_source_account") and r["match_source_account"] != source: continue
        if r.get("match_amount_min") is not None and amt < float(r["match_amount_min"]): continue
        if r.get("match_amount_max") is not None and amt > float(r["match_amount_max"]): continue
        debit = source if r["debit_account_code"] == "__SOURCE__" else r["debit_account_code"]
        credit = source if r["credit_account_code"] == "__SOURCE__" else r["credit_account_code"]
        return {"rule_id": r["id"], "rule_name": r["rule_name"],
                "debit_account_code": debit, "credit_account_code": credit,
                "sub_category_label": r.get("sub_category_label"),
                "confidence": r["confidence"], "is_suspense": r["confidence"] == "suspense"}
    return {"rule_id": None, "rule_name": "SUSPENSE (synthetic)",
            "debit_account_code": "QBO-SUSP", "credit_account_code": "QBO-SUSP",
            "sub_category_label": "Pending agent classification",
            "confidence": "suspense", "is_suspense": True}


def _post_je(agency_id: str, txn: dict, txn_date: str, cls: dict, doc_id: str | None) -> dict:
    reference = _make_ref(txn["source_account_code"], txn_date, txn["signed_amount"], txn["payee"])
    existing = _sql(f"""
        SELECT id FROM journal_entries
        WHERE agency_id = {_sql_escape(agency_id)} AND reference_number = {_sql_escape(reference)}
        LIMIT 1;
    """)
    if existing:
        return {"je_id": existing[0]["id"], "skipped": True, "is_suspense": cls["is_suspense"]}

    debit_id = _resolve_account_id(agency_id, cls["debit_account_code"])
    credit_id = _resolve_account_id(agency_id, cls["credit_account_code"])
    if not debit_id or not credit_id:
        raise RuntimeError(f"COA lookup failed: debit={cls['debit_account_code']} credit={cls['credit_account_code']}")

    description = (f"{txn['payee']} -- {cls['sub_category_label']}"
                   if cls.get("sub_category_label") else txn["payee"])

    je_rows = _sql(f"""
        INSERT INTO journal_entries (
          agency_id, entry_date, entry_type, reference_number, description, memo,
          source, document_id, classification_status, suspense_reason,
          rule_id_used, classified_by, classified_at
        ) VALUES (
          {_sql_escape(agency_id)}, {_sql_escape(txn_date)}, 'bank_txn',
          {_sql_escape(reference)}, {_sql_escape(description)},
          {_sql_escape(txn.get('memo') or None)},
          'document_processor_drainer',
          {_sql_escape(doc_id)},
          {_sql_escape('pending_review' if cls['is_suspense'] else 'classified')},
          {_sql_escape('no_rule_match' if cls['is_suspense'] else None)},
          {_sql_escape(cls.get('rule_id'))},
          {_sql_escape(None if cls['is_suspense'] else 'rule')},
          {('NULL' if cls['is_suspense'] else 'NOW()')}
        ) RETURNING id;
    """)
    if not je_rows: raise RuntimeError("JE insert returned no row")
    je_id = je_rows[0]["id"]
    amt = abs(txn["signed_amount"])
    _sql(f"""
        INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description) VALUES
          ({_sql_escape(je_id)}, {_sql_escape(agency_id)}, {_sql_escape(debit_id)},  {amt}, 0, {_sql_escape(description)}),
          ({_sql_escape(je_id)}, {_sql_escape(agency_id)}, {_sql_escape(credit_id)}, 0, {amt}, {_sql_escape(description)});
    """)
    return {"je_id": je_id, "skipped": False, "is_suspense": cls["is_suspense"]}


def _create_suspense_task(agency_id: str, je_id: str, txn: dict, txn_date: str) -> str:
    amount = abs(txn["signed_amount"])
    direction = "in" if txn["signed_amount"] > 0 else "out"
    priority = "high" if amount > 500 else ("medium" if amount >= 100 else "low")

    rows = _sql(f"""
        SELECT id, rule_name, debit_account_code, credit_account_code
        FROM gl_classification_rules
        WHERE agency_id = {_sql_escape(agency_id)} AND is_active=true AND confidence != 'suspense'
        ORDER BY match_priority ASC;
    """)
    payee_lower = txn["payee"].lower()
    memo_lower = (txn.get("memo") or "").lower()
    scored = []
    for r in rows:
        score = 0
        for w in re.split(r"\W+", r["rule_name"].lower()):
            if w and w in payee_lower: score += 2
            if w and w in memo_lower: score += 1
        scored.append((score, r))
    scored.sort(key=lambda x: -x[0])
    top3 = [s for s in scored[:3] if s[0] > 0]
    guesses = ("(no lexical matches -- please classify manually)" if not top3
               else "\n".join(f"  {i+1}. {s[1]['rule_name']} -> debit {s[1]['debit_account_code']}, credit {s[1]['credit_account_code']}"
                               for i, s in enumerate(top3)))

    title = f"Classify: ${amount:.2f} {direction} -- {txn['payee'][:50]}"
    description = (
        f"Suspense queue item -- needs classification.\n\n"
        f"Date: {txn_date}\nPayee: {txn['payee']}\nMemo: {txn.get('memo','')}\n"
        f"Amount: ${amount:.2f} ({direction})\nSource: {txn['source_account_code']}\nJE: {je_id}\n\n"
        f"Best guesses (lexical):\n{guesses}\n\n"
        f"Reply in chat with the number, the rule name, or your own classification. "
        f"I'll update the JE and add a new rule so this never hits suspense again."
    )
    out = _sql(f"""
        INSERT INTO tasks (agency_id, title, description, created_by, priority, status,
                           module_reference, related_id)
        VALUES (
          {_sql_escape(agency_id)}, {_sql_escape(title)}, {_sql_escape(description)},
          'llm_drainer', {_sql_escape(priority)}, 'open',
          'financials/suspense', {_sql_escape(je_id)}
        ) RETURNING id;
    """)
    return out[0]["id"] if out else ""


def _process_parse_bank(agency_id: str, row: dict, parsed: dict) -> dict:
    txns = parsed.get("transactions") or []
    je_count = 0; suspense_count = 0; skipped = 0
    source_account = "QBO-007"  # v1 fallback
    doc_id = row.get("document_id")
    for t in txns:
        if not isinstance(t.get("amount"), (int, float)) or not t.get("date"): continue
        payee = str(t.get("payee") or "").strip()
        if not payee: continue
        txn = {"payee": payee, "memo": str(t.get("memo") or "").strip(),
               "signed_amount": float(t["amount"]),
               "source_account_code": source_account}
        cls = _classify(agency_id, txn["payee"], txn["memo"], txn["signed_amount"], txn["source_account_code"])
        post = _post_je(agency_id, txn, str(t["date"]), cls, doc_id)
        if post["skipped"]: skipped += 1; continue
        je_count += 1
        if post["is_suspense"]:
            _create_suspense_task(agency_id, post["je_id"], txn, str(t["date"]))
            suspense_count += 1
    return {"je_count": je_count, "suspense_count": suspense_count, "skipped": skipped}


def drain_llm_queue(agency_id: str = AGENCY_ID, limit: int = DEFAULT_LIMIT) -> dict:
    claimed = _claim_pending(agency_id, limit)
    if not claimed:
        return {"claimed": 0, "succeeded": 0, "failed": 0, "retried": 0, "items": []}

    succeeded = failed = retried = 0
    items = []
    for row in claimed:
        item = {"id": row["id"], "purpose": row["purpose"], "attempt": row["attempts"],
                "status": None, "error": None, "downstream": None}
        try:
            llm_out, llm_err = invoke_llm(query=row["system_prompt"] + "\n\n" + row["user_content"])
            if llm_err: raise RuntimeError(f"invoke_llm error: {llm_err}")
            cleaned = _strip_fences(llm_out or "")
            try: parsed_json = json.loads(cleaned)
            except json.JSONDecodeError as je:
                raise RuntimeError(f"LLM returned non-JSON: {je}; raw={cleaned[:300]}")

            _mark_succeeded(row["id"], parsed_json, cleaned)
            succeeded += 1
            item["status"] = "succeeded"

            if row["purpose"] == "parse_bank_statement":
                item["downstream"] = _process_parse_bank(agency_id, row, parsed_json)
            elif row["purpose"] == "suspense_guesses":
                item["downstream"] = {"note": "result_json stored"}
        except Exception as e:
            err = str(e)
            new_status = _mark_retry_or_failed(row["id"], row["attempts"], err)
            item["status"] = new_status
            item["error"] = err[:300]
            if new_status == "failed":
                failed += 1
                _create_failure_task(agency_id, row, err)
            else:
                retried += 1
        items.append(item)

    return {"claimed": len(claimed), "succeeded": succeeded,
            "failed": failed, "retried": retried, "items": items}


def drain_llm_queue_until_empty(agency_id: str = AGENCY_ID, max_iters: int = 20) -> dict:
    total = {"iterations": 0, "claimed": 0, "succeeded": 0, "failed": 0, "retried": 0}
    for _ in range(max_iters):
        out = drain_llm_queue(agency_id, DEFAULT_LIMIT)
        total["iterations"] += 1
        for k in ("claimed", "succeeded", "failed", "retried"):
            total[k] += out[k]
        if out["claimed"] == 0: break
    return total
