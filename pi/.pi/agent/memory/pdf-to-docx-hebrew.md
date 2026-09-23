---
name: pdf-to-docx-hebrew
summary: pdf2docx (and LibreOffice PDF import) sort spans by x, which reverses Hebrew and drops paragraph direction — use ~/.local/bin/pdf2docx-rtl instead (rebuilds real RTL Word paragraphs from the PDF's logical text order)
pinned: true
created: 2026-09-22
modified: 2026-09-22
---
For Hebrew PDFs → DOCX, pdf2docx produced visual-order span text with no w:bidi/w:rtl and wrapped most of the body in single-row layout tables; unusable for editing.

~/.local/bin/pdf2docx-rtl <in.pdf> <out.docx> [--report] is my own converter (needs pymupdf + python-docx; run it with /tmp/pdfconv/bin/python or a uv venv). What it does:
- reads PyMuPDF spans in the PDF's own order (for RTL, same-baseline fragments arrive right-to-left = logical, and blocks are line-chunks, so it stably sorts blocks by y and merges fragments on one baseline), then merges visual lines into paragraphs (merge if gap<=18pt, previous line reaches x0<=100, and the x-ranges overlap; never merge across a clause number);
- writes w:bidi paragraphs, w:rtl runs, cs font, hanging clause numbers, indents from the PDF's geometry (skipped for short lines), spacing from measured y-gaps, and real tables (bidiVisual) for form boxes;
- preserves bold/italic/superscript, yellow highlights and underlines (detected as drawings, told apart from table rules by overlap).

Gotchas found the hard way:
- David (the font these Israeli government forms use) is NOT installed here; fc-list has Noto Serif Hebrew. A missing font wrecks the layout, and the script's DOC_FONT constant must name an installed font.
- CT_TblPr / CT_SectPr children must be inserted in schema order (bidiVisual before tblW; sectPr bidi before docGrid) or strict readers reject the file.
- Merging header cells in python-docx makes row.cells[0] and [1] the same cell — writing "" to [1] wipes the header.
- The PDF's spaces are geometry, not characters: insert a space when the gap between consecutive spans in a line is >1.5pt.
- Verify by comparing whitespace-stripped character streams (PDF logical vs docx body, tables separately) — that is what caught a dropped table header.
