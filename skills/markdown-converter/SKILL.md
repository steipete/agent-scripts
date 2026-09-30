---
name: markdown-converter
description: "Markdown conversion: PDF, Office, HTML, data, OCR, audio, ZIP, YouTube."
---

# Markdown Converter

Convert files to Markdown using `uvx --from "markitdown[all]" markitdown` — no installation required.

## Basic Usage

```bash
# Convert to stdout
uvx --from "markitdown[all]" markitdown input.pdf

# Save to file
uvx --from "markitdown[all]" markitdown input.pdf -o output.md
uvx --from "markitdown[all]" markitdown input.docx > output.md

# From stdin
cat input.pdf | uvx --from "markitdown[all]" markitdown
```

## Supported Formats

- **Documents**: PDF, Word (.docx), PowerPoint (.pptx), Excel (.xlsx, .xls)
- **Web/Data**: HTML, CSV, JSON, XML
- **Media**: Images (EXIF + OCR), Audio (EXIF + transcription)
- **Other**: ZIP (iterates contents), YouTube URLs, EPub

## Options

```bash
-o OUTPUT      # Output file
-x EXTENSION   # Hint file extension (for stdin)
-m MIME_TYPE   # Hint MIME type
-c CHARSET     # Hint charset (e.g., UTF-8)
-d             # Use Azure Document Intelligence
-e ENDPOINT    # Document Intelligence endpoint
--use-plugins  # Enable 3rd-party plugins
--list-plugins # Show installed plugins
```

## Examples

```bash
# Convert Word document
uvx --from "markitdown[all]" markitdown report.docx -o report.md

# Convert Excel spreadsheet
uvx --from "markitdown[all]" markitdown data.xlsx > data.md

# Convert PowerPoint presentation
uvx --from "markitdown[all]" markitdown slides.pptx -o slides.md

# Convert with file type hint (for stdin)
cat document | uvx --from "markitdown[all]" markitdown -x .pdf > output.md

# Use Azure Document Intelligence for better PDF extraction
uvx --from "markitdown[all]" markitdown scan.pdf -d -e "https://your-resource.cognitiveservices.azure.com/"
```

## Notes

- Output preserves document structure: headings, tables, lists, links
- First run caches dependencies; subsequent runs are faster
- For complex PDFs with poor extraction, use `-d` with Azure Document Intelligence
- If automatic charset detection picks the wrong encoding for a text file, pass `-c UTF-8` (or the known charset)
