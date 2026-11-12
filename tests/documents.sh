#!/usr/bin/env bash
# Run inside the image as agent; all fixtures are generated and removed here.
set -Eeuo pipefail
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
export DOC_TEST_DIR="$test_dir"
test "$(id -un)" = agent
pdftoppm -v
pdftotext -v
pandoc --version
glow --version
bat --version
tesseract --list-langs | tee "$test_dir/languages"
grep -Fx eng "$test_dir/languages"
grep -Fx pol "$test_dir/languages"
unzip -v
python3 -I -c 'import fitz, docx, openpyxl, pypdf, pdfplumber, pptx, PIL, lxml, bs4'
/usr/local/bin/python3 -I -c 'import pdfplumber, pptx'
python3 -I - <<'PY'
import os
from pathlib import Path
import fitz
from docx import Document
from PIL import Image, ImageDraw, ImageFont
from openpyxl import Workbook
from pptx import Presentation
root = Path(os.environ['DOC_TEST_DIR'])
image = Image.new('RGB', (1000, 200), 'white')
draw = ImageDraw.Draw(image)
draw.text((30, 50), 'Scanned document example', font=ImageFont.truetype('DejaVuSans.ttf', 48), fill='black')
image.save(root / 'picture.png')
doc = Document()
doc.add_heading('Document tooling example', 1)
doc.add_picture(str(root / 'picture.png'))
doc.save(root / 'example.docx')
pdf = fitz.open()
page = pdf.new_page()
page.insert_text((72, 72), 'Document tooling example')
page.insert_image(fitz.Rect(72, 100, 500, 200), filename=str(root / 'picture.png'))
page = pdf.new_page()
page.insert_image(fitz.Rect(30, 100, 580, 210), filename=str(root / 'picture.png'))
pdf.save(root / 'example.pdf')
book = Workbook()
book.active.append(['Document tooling example', 42])
book.save(root / 'example.xlsx')
slides = Presentation()
slide = slides.slides.add_slide(slides.slide_layouts[1])
slide.shapes.title.text = 'Document tooling example'
slides.save(root / 'example.pptx')
(root / 'example.html').write_text('<h1>Document tooling example</h1>')
(root / 'vector.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect x="10" y="10" width="80" height="80" fill="red"/></svg>')
PY
# Generate both Windows vector formats, then place them in an Office media archive.
for kind in emf wmf; do
    inkscape "$test_dir/vector.svg" --export-type="$kind" --export-filename="$test_dir/vector.$kind"
done
python3 -I - <<'PY'
import os, zipfile
from pathlib import Path
root = Path(os.environ['DOC_TEST_DIR'])
with zipfile.ZipFile(root / 'vectors.docx', 'w') as archive:
    for kind in ('emf', 'wmf'):
        archive.write(root / f'vector.{kind}', f'word/media/vector.{kind}')
PY
doc-extract-images "$test_dir/vectors.docx" "$test_dir/vectors"
test "$(find "$test_dir/vectors" -name '*.png' -size +0c | wc -l)" -eq 2
if command -v soffice >/dev/null; then
    mkdir "$test_dir/office"
    soffice --headless "-env:UserInstallation=file://$test_dir/lo-profile" --convert-to pdf --outdir "$test_dir/office" "$test_dir/example.docx"
    test -s "$test_dir/office/example.pdf"
fi
mammoth "$test_dir/example.docx" "$test_dir/mammoth.html"
grep -q 'Document tooling example' "$test_dir/mammoth.html"
sha256sum "$test_dir"/example.* > "$test_dir/source-hashes"
for kind in pdf docx xlsx pptx html; do
    doc-to-text "$test_dir/example.$kind" "$test_dir/text-$kind"
    grep -q 'Document tooling example' "$test_dir/text-$kind/document.md"
done
grep -q 'Scanned document example' "$test_dir/text-pdf/document.md"
for kind in pdf docx; do
    doc-extract-images "$test_dir/example.$kind" "$test_dir/images-$kind"
    test -n "$(find "$test_dir/images-$kind" -name '*.png' -size +0c -print -quit)"
done
pdf-to-png "$test_dir/example.pdf" 1 2 110 --outdir "$test_dir/pages"
test -s "$test_dir/pages/page-1.png"
test -s "$test_dir/pages/page-2.png"
sha256sum -c "$test_dir/source-hashes"
python3 -I - <<'PY'
import os
from pathlib import Path
from PIL import Image
root = Path(os.environ['DOC_TEST_DIR'])
for directory in ('images-pdf', 'images-docx', 'vectors'):
    for path in (root / directory).glob('*.png'):
        with Image.open(path) as image:
            assert max(image.size) <= 1600, path
PY
for tool in doc-to-text doc-extract-images pdf-to-png; do "$tool" --help; done
if doc-to-text "$test_dir/example.pdf" "$test_dir"; then
    echo 'Helper accepted an output directory containing its source' >&2; exit 1
fi
echo 'Document tests passed: text, OCR, embedded images, page rendering and imports.'
