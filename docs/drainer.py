# =========================================================================
# docs/drainer.py -- LLM Parse Queue Drainer (v1.3)
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
#   v1.3 (2026-06-19): (a) Fixed _download_from_storage missing the
#     `apikey` header -- the new sb_secret_ Supabase keys reject
#     storage requests that only carry Authorization: Bearer (legacy
#     JWT keys did not need the apikey header). Symptom: storage GET
#     returned HTTP 400 silently, drainer reported "extracted text
#     too short" instead of the real auth failure.
#   v1.3 (2026-06-19): (b) Removed comp_recap_daily / deduction_statement
#     LLM prompts. Those doc types are now parsed deterministically
#     INLINE by the document-processor edge function via
#     parsers/comp_recap.ts and parsers/deduction.ts (regex-based, no
#     LLM). The queue path is no longer used for those doc types --
#     it produced two recurring bugs: (i) silent payload truncation
#     on bigger comp PDFs, (ii) wrong-column extraction (YTD instead
#     of CURRENT) on deduction statements. If a comp/deduction PDF
#     ever lands in this queue manually, the parse_pdf_to_text
#     handler now refuses it with a clear message pointing back to
#     the doc-processor inline path.
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
    # IMPORTANT: New sb_secret_* keys require BOTH Authorization: Bearer
    # AND apikey headers. Legacy JWT keys worked with just Authorization;
    # newer keys 400 silently without apikey. Always send both. See v1.3
    # changelog.
    r = requests.get(
        url,
        headers={
            "Authorization": f"Bearer {_STORAGE_KEY}",
            "apikey": _STORAGE_KEY,
        },
        timeout=60,
    )
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


# === PDF/text extraction handler ===================================
#
# NOTE: v1.3 removed the LLM prompts for comp_recap_daily and
# deduction_statement. Those doc types are now parsed deterministically
# INLINE by the document-processor edge function via
# parsers/comp_recap.ts and parsers/deduction.ts (regex-based). If a
# row of either doc_type lands here, _process_parse_pdf_to_text refuses
# it and the queue row fails fast with a clear error message.


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

    # v1.3: comp_recap_daily / deduction_statement are now handled by
    # the doc-processor inline path (deterministic regex parser). If we
    # see one here, fail fast with a pointer to the right path.
    doc_type = row.get('doc_type')
    if doc_type in ('comp_recap_daily', 'deduction_statement'):
        raise RuntimeError(
            f"doc_type={doc_type} is no longer drained via the LLM queue. "
            f"It should be parsed inline by document-processor "
            f"(parsers/comp_recap.ts or parsers/deduction.ts). "
            f"If it landed here, the doc-processor edge function failed "
            f"upstream -- check its logs and re-run."
        )
    # Other doc_types: extract text for downstream inspection, no LLM call.
    return {
        "extracted_chars": len(text),
        "extracted_text": text,
        "llm_rows": 0,
        "inserted": 0,
        "target_table": None,
        "note": f"text extracted but no parser configured for doc_type={doc_type}",
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
