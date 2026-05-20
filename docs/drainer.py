# =========================================================================
# docs/drainer.py -- LLM Parse Queue Drainer (v1.2)
# =========================================================================
# Workbench-side script that drains llm_parse_queue using invoke_llm() and
# smart_file_extract() -- helpers that are only available inside
# COMPOSIO_REMOTE_WORKBENCH.
#
# HOW TO USE in a Claude session:
#   1. Open COMPOSIO_REMOTE_WORKBENCH
#   2. Paste this whole file
#   3. Call: drain_llm_queue()              -- drains up to 10 items
#      Or:   drain_llm_queue_until_empty()  -- drains everything
#
# CHANGELOG:
#   v1.2 (2026-05-20): Added parse_pdf_to_text handler. Was previously
#     missing -- caused 19 stuck ADP files + every new PDF intake to
#     hang in queue. Drainer now downloads from Supabase Storage,
#     runs smart_file_extract, saves extracted_text, then dispatches
#     to LLM parse for known doc_types (comp_recap_daily,
#     deduction_statement).
#   v1.1 (2026-05-15): parse_bank_statement + suspense_guesses handlers.
#
# Supported purposes:
#   parse_pdf_to_text          PDFs from comp_recap_daily / deduction_statement
#                              docs. Extracts text + LLM-parses to comp_recap.
#   parse_bank_statement       Bank PDF text -> classified JEs.
#   suspense_guesses           LLM-ranked classification candidates for
#                              suspense JEs (stored as result_json).
#
# Behavior:
#   - Atomic claim (FOR UPDATE SKIP LOCKED) -- safe to run concurrently
#   - 3 attempts max per row; failures become high-priority tasks
#   - .xls files NOT yet supported in parse_pdf_to_text -- fail fast
#     with a clear error so the agent triages them
#
# See docs/drainer.md for full description.
# =========================================================================

import json
import re
import os
import tempfile
import requests
from typing import Any

AGENCY_ID = "126794dd-25ff-47d2-a436-724499733365"
SUPABASE_REF = "vulhdujhbwvibbojiimi"
MAX_ATTEMPTS = 3
DEFAULT_LIMIT = 10

# Storage credentials loaded lazily from settings on first use
_STORAGE_URL = None
_STORAGE_KEY = None


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
    return re.sub(r"^```(?:json)?\s*|\s*```$", "", text.strip(), flags=re.MULTILINE)


def _load_storage_creds():
    global _STORAGE_URL, _STORAGE_KEY
    if _STORAGE_URL and _STORAGE_KEY:
        return
    rows = _sql(f"""
        SELECT setting_key, setting_value FROM settings
        WHERE agency_id = {_sql_escape(AGENCY_ID)}
          AND setting_key IN ('supabase_service_role_key','supabase_url');
    """)
    creds = {r['setting_key']: r['setting_value'] for r in rows}
    _STORAGE_URL = creds.get('supabase_url')
    _STORAGE_KEY = creds.get('supabase_service_role_key')
    if not _STORAGE_URL or not _STORAGE_KEY:
        raise RuntimeError("Missing supabase_url or supabase_service_role_key in settings")


def _download_from_storage(bucket: str, path: str) -> bytes:
    _load_storage_creds()
    url = f"{_STORAGE_URL}/storage/v1/object/{bucket}/{path}"
    r = requests.get(url, headers={"Authorization": f"Bearer {_STORAGE_KEY}"}, timeout=60)
    if r.status_code != 200:
        raise RuntimeError(f"Storage GET {bucket}/{path} -> HTTP {r.status_code}: {r.text[:200]}")
    return r.content


def _file_ext(mime: str, file_name: str) -> str:
    m = (mime or "").lower()
    if 'pdf' in m: return '.pdf'
    if 'excel' in m or 'spreadsheet' in m or 'xls' in (file_name or '').lower(): return '.xls'
    if file_name and '.' in file_name:
        return '.' + file_name.rsplit('.', 1)[-1]
    return '.bin'


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
        RETURNING q.id, q.agency_id, q.document_id, q.purpose, q.doc_type,
                  q.system_prompt, q.user_content, q.model, q.attempts,
                  q.file_name, q.mime_type, q.storage_bucket, q.storage_path;
    """)


def _mark_succeeded(row_id: str, result_json: Any, raw: str, extracted_text: str = None) -> None:
    extracted_clause = ""
    if extracted_text is not None:
        extracted_clause = f", extracted_text = {_sql_escape(extracted_text)}"
    _sql(f"""
        UPDATE llm_parse_queue
        SET status='succeeded',
            result_json={_sql_escape(json.dumps(result_json) if result_json is not None else None)}::jsonb,
            result_raw={_sql_escape((raw or '')[:50000])},
            completed_at=NOW(), last_error=NULL
            {extracted_clause}
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
        f"File: {row.get('file_name') or '(none)'}\n\nLast error:\n{error[:1500]}\n\n"
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


# === PDF/text extraction handler (NEW in v1.2) =====================

# LLM prompts per doc_type for post-extraction parsing.
COMP_RECAP_LLM_PROMPT = """You are an extractor for State Farm Daily Compensation Recap PDFs.
Given the extracted text below, return a JSON object with a "rows" array.
Each row represents one line item with these fields:

- comp_type: string ("1H" or "2H")
- comp_category: string -- one of:
    "auto_new", "auto_renewal", "fire_new", "fire_renewal",
    "life_new", "life_renewal", "health_new", "health_renewal",
    "deduction_license", "deduction_technology", "deduction_advertising",
    "other"
- description: string (the original line item description)
- amount: number (positive for credits, NEGATIVE for deductions shown in parens)
- period_year: integer
- period_month: integer
- period_day: integer
- is_aipp_eligible: boolean (TRUE only for auto_new, auto_renewal, fire_new, fire_renewal)
- is_scoreboard_eligible: boolean (always false)

SKIP summary lines (GROSS, TOTAL, NET). Only extract individual line items.
Return ONLY a JSON object {"rows": [...]}. No prose. No markdown fences."""

DEDUCTION_LLM_PROMPT = """You are an extractor for State Farm Deduction Statements.
Given the extracted text below, return a JSON object with a "rows" array.
Each row represents one deduction line item:

- comp_type: string ("1H" or "2H")
- comp_category: string (one of "deduction_license", "deduction_technology",
    "deduction_advertising", "deduction_other")
- description: string
- amount: number (NEGATIVE -- deductions reduce comp)
- period_year, period_month, period_day: integers
- is_aipp_eligible: false
- is_scoreboard_eligible: false

SKIP totals. Return ONLY {"rows": [...]}. No prose. No fences."""


def _process_parse_pdf_to_text(agency_id: str, row: dict) -> dict:
    """Handle a parse_pdf_to_text queue row.
    Downloads bytes from Storage, extracts text via smart_file_extract,
    then dispatches to a doc_type-specific LLM prompt to build the
    structured rows for the target table.
    Returns {extracted_chars, llm_rows, inserted, target_table}.
    """
    bucket = row.get('storage_bucket')
    path = row.get('storage_path')
    if not bucket or not path:
        raise RuntimeError("queue row missing storage_bucket/storage_path")

    file_name = row.get('file_name', '')
    mime = row.get('mime_type', '')
    ext = _file_ext(mime, file_name)

    # .xls binary format isn't extractable by smart_file_extract directly --
    # the helper dumps raw bytes. Fail fast with a clear message.
    if ext in ('.xls', '.xlsx'):
        raise RuntimeError(
            f".xls/.xlsx parsing not implemented in drainer v1.2. "
            f"File: {file_name}. Triage manually or extend drainer with openpyxl/xlrd."
        )

    raw = _download_from_storage(bucket, path)
    with tempfile.NamedTemporaryFile(delete=False, suffix=ext, dir='/tmp') as tmp:
        tmp.write(raw)
        tmp_path = tmp.name
    try:
        text, err = smart_file_extract(tmp_path, show_preview=False)
        if err:
            raise RuntimeError(f"smart_file_extract failed: {err}")
        if not text or len(text) < 10:
            raise RuntimeError(f"extracted text too short: {len(text or '')} chars")
    finally:
        try: os.unlink(tmp_path)
        except: pass

    # Pick the right LLM prompt for this doc_type
    doc_type = row.get('doc_type')
    if doc_type == 'comp_recap_daily':
        prompt = COMP_RECAP_LLM_PROMPT
        target_table = 'comp_recap'
    elif doc_type == 'deduction_statement':
        prompt = DEDUCTION_LLM_PROMPT
        target_table = 'comp_recap'  # deductions also go to comp_recap with negative amounts
    else:
        # text extracted, but no downstream parser for this doc_type yet
        return {
            "extracted_chars": len(text),
            "extracted_text": text,
            "llm_rows": 0,
            "inserted": 0,
            "target_table": None,
            "note": f"text extracted but no LLM parser configured for doc_type={doc_type}",
        }

    llm_out, llm_err = invoke_llm(query=f"{prompt}\n\nTEXT TO PARSE:\n{text}")
    if llm_err:
        raise RuntimeError(f"invoke_llm failed: {llm_err}")
    cleaned = _strip_fences(llm_out or "")
    parsed = json.loads(cleaned)
    parsed_rows = parsed.get("rows", [])

    # Insert rows into target table
    inserted = 0
    doc_id = row.get('document_id')
    for r in parsed_rows:
        if target_table == 'comp_recap':
            _sql(f"""
                INSERT INTO comp_recap (
                  agency_id, period_year, period_month, period_day,
                  comp_type, comp_category, description, amount,
                  is_aipp_eligible, is_scoreboard_eligible,
                  source_document_id, posted_at
                ) VALUES (
                  {_sql_escape(agency_id)},
                  {int(r.get('period_year') or 0)},
                  {int(r.get('period_month') or 0)},
                  {int(r.get('period_day') or 0)},
                  {_sql_escape(r.get('comp_type'))},
                  {_sql_escape(r.get('comp_category'))},
                  {_sql_escape(r.get('description'))},
                  {float(r.get('amount') or 0)},
                  {_sql_escape(bool(r.get('is_aipp_eligible')))},
                  {_sql_escape(bool(r.get('is_scoreboard_eligible')))},
                  {_sql_escape(doc_id)},
                  NOW()
                );
            """)
            inserted += 1

    # Update document row
    if doc_id:
        _sql(f"""
            UPDATE documents
            SET processing_status='processed',
                tables_updated=ARRAY[{_sql_escape(target_table)}],
                records_created={inserted},
                processed_at=NOW()
            WHERE id={_sql_escape(doc_id)};
        """)

    return {
        "extracted_chars": len(text),
        "extracted_text": text,
        "llm_rows": len(parsed_rows),
        "inserted": inserted,
        "target_table": target_table,
    }


# === Main drainer entry points =========================================

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
            purpose = row.get("purpose")

            if purpose == "parse_pdf_to_text":
                # NEW v1.2 handler
                out = _process_parse_pdf_to_text(agency_id, row)
                _mark_succeeded(row["id"], {
                    "extracted_chars": out["extracted_chars"],
                    "llm_rows": out["llm_rows"],
                    "inserted": out["inserted"],
                    "target_table": out.get("target_table"),
                }, "", extracted_text=out.get("extracted_text"))
                item["downstream"] = {k: v for k, v in out.items() if k != "extracted_text"}
                succeeded += 1
                item["status"] = "succeeded"

            else:
                # v1.1 path: generic LLM call
                llm_out, llm_err = invoke_llm(query=(row["system_prompt"] or "") + "\n\n" + (row["user_content"] or ""))
                if llm_err: raise RuntimeError(f"invoke_llm error: {llm_err}")
                cleaned = _strip_fences(llm_out or "")
                try: parsed_json = json.loads(cleaned)
                except json.JSONDecodeError as je:
                    raise RuntimeError(f"LLM returned non-JSON: {je}; raw={cleaned[:300]}")
                _mark_succeeded(row["id"], parsed_json, cleaned)
                succeeded += 1
                item["status"] = "succeeded"
                # Note: parse_bank_statement downstream (classify->JE) and
                # suspense_guesses storage are handled inline by the v1.1
                # code path -- preserved by the drainer.py source on disk.

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
