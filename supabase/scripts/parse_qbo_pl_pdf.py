"""
QBO Profit-and-Loss PDF parser for Newtworks prior_year_pl ingest.

Converts a QBO-exported "By Month" P&L PDF into row-per-(year, month, section, account)
records suitable for the public.prior_year_pl table.

USAGE
-----
1. Save the QBO PDF (Profit and Loss > Show columns: Months > Export to PDF).
2. Convert to layout-preserved text: pdftotext -layout input.pdf input.txt
3. Run this parser with the correct boundary_shift for that file's column density.
4. POST results as JSON to Supabase REST via
   /rest/v1/prior_year_pl?on_conflict=agency_id,business_entity_id,period_year,period_month,section,account_name
   with Prefer: resolution=merge-duplicates,return=minimal.

DESIGN NOTES
------------
- Section labels are stripped of any percent-goal suffix (e.g. "0001 ADMINISTRATION 6% > 5%"
  -> "0001 ADMINISTRATION"). Percent goals are rendered at UI time from
  envelope_budget_targets.
- Ghost entries in the source (e.g. "Ghost Tithe - 12%") are preserved verbatim as
  account_name.
- source_entity is stored verbatim from the QBO title bar (e.g. "Peter J Story State Farm
  Agency"). This is the QBO business as titled at export time; do not "normalize".
- boundary_shift is a per-file tuning parameter for the position-based fallback column
  assignment. pdftotext -layout emits column widths that vary with the number of columns
  and their max-amount widths. Empirically: 12-month (13-column) 2025 export uses shift=-5.
  Partial-year 2026 YTD (5-month, 6-column) works at shift=-3.
- When a row has exactly (n_months + 1) amounts (all months + TOTAL), amounts are assigned
  sequentially. When fewer, midpoint-boundary fallback with the boundary_shift kicks in.

RECONCILIATION
--------------
Every section subtotal in the parsed output must equal the corresponding "Total for X" row
in the source PDF. 2025 full-year and 2026 YTD both reconcile to $0.00 diff.
"""

import re
from decimal import Decimal

AMOUNT_RE = re.compile(r'-?\$?[\d,]+\.\d{2}')

MONTH_MAP = {
    'JAN': 1, 'FEB': 2, 'MAR': 3, 'APR': 4, 'MAY': 5, 'JUN': 6,
    'JUL': 7, 'AUG': 8, 'SEP': 9, 'OCT': 10, 'NOV': 11, 'DEC': 12,
}

SECTION_TYPE_MARKERS = {
    'Income': 'Income',
    'Expenses': 'Expense',
    'Expense': 'Expense',
}


def strip_percent_suffix(section):
    """Strip trailing percent-goal suffix. '0001 ADMINISTRATION 6% > 5%> 5%' -> '0001 ADMINISTRATION'."""
    return re.sub(r'\s+\d+%(\s*>\s*\d+%)*\s*$', '', section).strip()


def reconstruct_records(lines):
    """
    Walk raw lines, joining multi-line records (name-continuation lines get merged into
    the previous record's name field, but the original amount-line position is preserved
    so column detection stays anchored to the true amount positions).

    Returns list of {name, orig_amount_line, has_amounts, is_skip, is_total}.
    """
    records = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1; continue

        stripped = line.strip()

        # Skip totals / summary lines
        if stripped.startswith('Total for') or stripped.startswith('Net Income') \
           or stripped.startswith('Net Operating Income'):
            is_total = stripped.startswith('Total for')
            # Consume continuation lines (percent-suffix wraps)
            j = i + 1
            while j < len(lines):
                nxt = lines[j]
                if not nxt.strip(): break
                if AMOUNT_RE.search(nxt): break
                nxt_stripped = nxt.strip()
                if re.match(r'^(Total for|Net Income|Net Operating Income|\d{4}[a-z]?\s|[A-Z][A-Z0-9\s%>&/-]+$)', nxt_stripped):
                    break
                if re.match(r'^\d+%(\s*>\s*\d+%)*\s*$', nxt_stripped) or nxt_stripped in SECTION_TYPE_MARKERS:
                    j += 1; continue
                if re.match(r'^[A-Z0-9\s%>&/-]+$', nxt_stripped):
                    j += 1; continue
                break
            records.append({'name': stripped, 'orig_amount_line': line, 'has_amounts': False,
                            'is_skip': True, 'is_total': is_total})
            i = j; continue

        # Determine if this line has amounts (data row) vs is a name/section header
        has_amounts = bool(AMOUNT_RE.search(line))

        # Look ahead: absorb name-continuation lines (no amounts, not section headers)
        j = i + 1
        merged_name = stripped
        while j < len(lines):
            nxt = lines[j]
            if not nxt.strip(): break
            if AMOUNT_RE.search(nxt): break
            nxt_stripped = nxt.strip()
            if nxt_stripped.startswith('Total for') or nxt_stripped.startswith('Net Income') \
               or nxt_stripped.startswith('Net Operating Income'):
                break
            if nxt_stripped in SECTION_TYPE_MARKERS: break
            # Merge continuation into name
            merged_name = merged_name + ' ' + nxt_stripped
            j += 1

        records.append({'name': merged_name, 'orig_amount_line': line,
                        'has_amounts': has_amounts, 'is_skip': False, 'is_total': False})
        i = j

    return records


def extract_amounts_by_column(line, month_cols, total_end_pos, boundary_shift=-3):
    """
    Two-mode column assignment:
    - Row has exactly (n_months + 1) amounts: sequential 1:1 (last -> TOTAL, dropped).
    - Otherwise: midpoint boundaries with left-shift to handle pdftotext-layout drift.
    """
    amounts = list(AMOUNT_RE.finditer(line))
    result = {}
    if not amounts:
        return result
    n_months = len(month_cols)

    if len(amounts) == n_months + 1:
        for i, m in enumerate(amounts[:n_months]):
            raw = m.group(0).replace('$', '').replace(',', '')
            try:
                val = Decimal(raw)
            except Exception:
                continue
            result[month_cols[i]['col_idx']] = val
        return result

    ordered = sorted(month_cols, key=lambda c: c['end_pos'])
    ends = [c['end_pos'] for c in ordered]
    boundaries = [(ends[i] + ends[i + 1]) / 2 + boundary_shift for i in range(len(ends) - 1)]
    if total_end_pos is not None:
        boundaries.append((ends[-1] + total_end_pos) / 2 + boundary_shift)

    def col_for(pos):
        for i, b in enumerate(boundaries):
            if pos <= b:
                return ordered[i]['col_idx']
        return -1  # past TOTAL boundary

    for m in amounts:
        amt_end = m.end()
        raw = m.group(0).replace('$', '').replace(',', '')
        try:
            val = Decimal(raw)
        except Exception:
            continue
        cid = col_for(amt_end)
        if cid == -1:
            continue
        result[cid] = val
    return result


def parse_page(page_text, year, partial_end_date, cst, cs, boundary_shift):
    page_rows = []
    lines = page_text.split('\n')
    header_idx = None
    for i, l in enumerate(lines):
        if 'TOTAL' in l and re.search(r'JAN\s+\d{4}', l):
            header_idx = i
            break
    if header_idx is None:
        return page_rows, cst, cs

    header = lines[header_idx]
    label_re = re.compile(r'((?:JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)(?:\s+\d+-\d+)?\s+\d{4})|(TOTAL)')
    col_matches = [{'label': m.group(0), 'end': m.end()} for m in label_re.finditer(header)]

    month_cols = []
    total_end_pos = None
    for idx, cm in enumerate(col_matches):
        if cm['label'] == 'TOTAL':
            total_end_pos = cm['end']
            continue
        month_str = cm['label'].split()[0]
        month = MONTH_MAP.get(month_str)
        if not month:
            continue
        month_cols.append({
            'col_idx': idx,
            'month': month,
            'is_partial': bool(re.search(r'\d+-\d+', cm['label'])),
            'end_pos': cm['end'],
        })

    records = reconstruct_records(lines[header_idx + 1:])
    for rec in records:
        if rec['is_skip']:
            if rec['is_total']:
                cs = 'root'
            continue
        stripped_name = rec['name']
        if stripped_name in SECTION_TYPE_MARKERS:
            cst = SECTION_TYPE_MARKERS[stripped_name]
            cs = 'root'
            continue
        if rec['has_amounts']:
            amounts = extract_amounts_by_column(
                rec['orig_amount_line'], month_cols, total_end_pos, boundary_shift)
            for c in month_cols:
                amt = amounts.get(c['col_idx'])
                if amt is None:
                    continue
                page_rows.append({
                    'year': year,
                    'month': c['month'],
                    'section_type': cst or 'Expense',
                    'section': strip_percent_suffix(cs),
                    'account_name': stripped_name,
                    'amount': str(amt),
                    'is_partial_period': c['is_partial'],
                    'period_actual_end_date': partial_end_date if c['is_partial'] else None,
                })
        else:
            if re.match(r'^\d{4}[a-z]?\s', stripped_name) or re.match(r'^[A-Z][A-Z0-9\s%>&/-]+$', stripped_name):
                cs = stripped_name

    return page_rows, cst, cs


def parse_pdf_text(text, year, partial_end_date=None, boundary_shift=-3):
    """
    Parse pdftotext -layout output of a QBO By-Month P&L export.

    Args:
        text: Output of `pdftotext -layout export.pdf export.txt`.
        year: Fiscal year (e.g. 2025).
        partial_end_date: For YTD exports, the actual end date (ISO string). None for full year.
        boundary_shift: Per-file column-boundary tuning. Empirical values:
            - Full 12-month (13-col) export: -5
            - Partial 5-month (6-col) export: -3

    Returns:
        List of dicts, one per (year, month, section, account) row.
    """
    all_rows = []
    cst, cs = None, 'root'
    for page in text.split('\f'):
        page_rows, cst, cs = parse_page(page, year, partial_end_date, cst, cs, boundary_shift)
        all_rows.extend(page_rows)
    return all_rows


if __name__ == '__main__':
    import sys, json
    if len(sys.argv) < 4:
        print("Usage: parse_qbo_pl_pdf.py <text_file> <year> <boundary_shift> [partial_end_date]")
        print("Example: parse_qbo_pl_pdf.py 2025_full.txt 2025 -5")
        print("         parse_qbo_pl_pdf.py 2026_ytd.txt 2026 -3 2026-05-11")
        sys.exit(1)
    text_path = sys.argv[1]
    year = int(sys.argv[2])
    shift = int(sys.argv[3])
    partial = sys.argv[4] if len(sys.argv) > 4 else None
    with open(text_path) as f:
        text = f.read()
    rows = parse_pdf_text(text, year, partial, shift)
    print(json.dumps(rows, indent=2, default=str))
