from docx import Document
from docx.shared import Pt, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_LINE_SPACING
from docx.oxml.ns import qn
from docx.oxml import OxmlElement
import copy

doc = Document()

def set_style(style, font_name="Times New Roman", font_size=12,
              bold=False, space_before=0, space_after=6,
              line_spacing=1.5, alignment=WD_ALIGN_PARAGRAPH.JUSTIFY):
    style.font.name = font_name
    style.font.size = Pt(font_size)
    style.font.bold = bold
    style.paragraph_format.alignment = alignment
    style.paragraph_format.space_before = Pt(space_before)
    style.paragraph_format.space_after = Pt(space_after)
    style.paragraph_format.line_spacing_rule = WD_LINE_SPACING.MULTIPLE
    style.paragraph_format.line_spacing = line_spacing
    # Force Times New Roman in XML for compatibility
    rpr = style.element.get_or_add_rPr()
    rFonts = OxmlElement("w:rFonts")
    rFonts.set(qn("w:ascii"), font_name)
    rFonts.set(qn("w:hAnsi"), font_name)
    rFonts.set(qn("w:cs"), font_name)
    rpr.append(rFonts)

set_style(doc.styles["Normal"])
set_style(doc.styles["Body Text"], space_after=8)

for h, size, bold in [("Heading 1", 14, True), ("Heading 2", 13, True), ("Heading 3", 12, True)]:
    s = doc.styles[h]
    set_style(s, font_size=size, bold=bold, space_before=12, space_after=6,
              alignment=WD_ALIGN_PARAGRAPH.LEFT)

# Table style — plain
for ts in doc.styles:
    if ts.name == "Table Grid":
        ts.font.name = "Times New Roman"
        ts.font.size = Pt(11)

doc.save("reference.docx")
print("reference.docx criado")
