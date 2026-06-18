#!/usr/bin/env python3
"""OCR all pages of a chess book PDF and save raw text to JSON.

Usage:
    python ocr_pages.py <pdf_path> [output.json] [--start N] [--end N]

The output JSON maps 1-indexed page numbers (as strings) to OCR text.
Run this once — it's slow (~3s per page). The build_pgn.py script
reads this JSON for the fast, iterable parsing step.
"""

import argparse
import io
import json
import sys
import time

import fitz  # pymupdf
import pytesseract
from PIL import Image


def ocr_page(page, dpi=300):
    """Render a single PDF page and OCR it."""
    mat = fitz.Matrix(dpi / 72, dpi / 72)
    pix = page.get_pixmap(matrix=mat)
    img = Image.open(io.BytesIO(pix.tobytes("png")))
    return pytesseract.image_to_string(img)


def ocr_pdf(pdf_path, start=0, end=None, dpi=300):
    """OCR pages [start, end) of a PDF. Returns {page_num_str: text}."""
    doc = fitz.open(pdf_path)
    if end is None or end > len(doc):
        end = len(doc)

    results = {}
    t0 = time.time()
    for i in range(start, end):
        text = ocr_page(doc[i], dpi=dpi)
        results[str(i + 1)] = text
        elapsed = time.time() - t0
        rate = elapsed / (i - start + 1)
        eta = rate * (end - i - 1)
        print(
            f"  Page {i + 1:3d}/{end}  "
            f"({len(text):5d} chars)  "
            f"[{elapsed:.0f}s elapsed, ~{eta:.0f}s remaining]"
        )

    doc.close()
    return results


def main():
    parser = argparse.ArgumentParser(description="OCR a chess book PDF to JSON")
    parser.add_argument("pdf", help="Path to PDF file")
    parser.add_argument("output", nargs="?", default="ocr_output.json",
                        help="Output JSON path (default: ocr_output.json)")
    parser.add_argument("--start", type=int, default=1,
                        help="First page to OCR (1-indexed, default 1)")
    parser.add_argument("--end", type=int, default=None,
                        help="Last page to OCR (inclusive, default: last page)")
    parser.add_argument("--dpi", type=int, default=300,
                        help="Render DPI (default 300)")
    args = parser.parse_args()

    start_idx = args.start - 1  # convert to 0-indexed
    end_idx = args.end  # kept as-is (exclusive in range), or None for all

    print(f"OCR-ing {args.pdf}")
    print(f"  Pages {args.start}–{args.end or 'end'}, DPI {args.dpi}")
    print()

    results = ocr_pdf(args.pdf, start=start_idx, end=end_idx, dpi=args.dpi)

    with open(args.output, "w") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)

    print(f"\nSaved {len(results)} pages to {args.output}")


if __name__ == "__main__":
    main()
