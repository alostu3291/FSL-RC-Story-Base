"""Build the Brightline Commercial DocGen templates (docx): the planned maintenance contract proposal
priced site by site, the capital project proposal with its milestone schedule, and the consolidated
invoice with a subtotal per site.

Usage:
    python scripts/docgen/build_hvac_commercial_docs.py \
        scripts/docgen/assets/brightline_logo_white.png \
        unpackaged/post_hvac_commercial_docgen/documentTemplates

Tokens must match the extracts in build_hvac_commercial_odts.py and each template's tokenList.
"""
import os
import sys
from docx import Document
from docx.enum.table import WD_CELL_VERTICAL_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Inches, Pt, RGBColor

NAVY = "1B3A5C"
GLACIER = "3BA7D9"
EMBER = "F26B3A"
INK = "1E2A35"
GREY = "5A6470"
TINT = "EEF3F7"
RULE = "D5DFE8"
LOGO_WHITE = sys.argv[1]
OUT_DIR = sys.argv[2]
CONTENT_W = 7.3
RIGHT = WD_ALIGN_PARAGRAPH.RIGHT


def new_doc():
    doc = Document()
    sec = doc.sections[0]
    sec.page_width, sec.page_height = Inches(8.5), Inches(11)
    sec.left_margin = sec.right_margin = Inches(0.6)
    sec.top_margin = Inches(0.5)
    sec.bottom_margin = Inches(0.6)
    sec.header_distance = Inches(0.3)
    sec.footer_distance = Inches(0.3)
    normal = doc.styles["Normal"]
    normal.font.name = "Arial"
    normal.element.rPr.rFonts.set(qn("w:eastAsia"), "Arial")
    normal.font.size = Pt(9.5)
    normal.font.color.rgb = RGBColor.from_string(INK)
    normal.paragraph_format.space_after = Pt(0)
    normal.paragraph_format.space_before = Pt(0)
    return doc


def shade(cell, hex_color):
    tcPr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), hex_color)
    tcPr.append(shd)


def borders(table, color=None, inside_h=False):
    tblPr = table._tbl.tblPr
    b = OxmlElement("w:tblBorders")
    for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
        e = OxmlElement(f"w:{edge}")
        if color and (edge == "insideH" and inside_h or edge == "bottom"):
            e.set(qn("w:val"), "single")
            e.set(qn("w:sz"), "4")
            e.set(qn("w:color"), color)
        else:
            e.set(qn("w:val"), "nil")
        b.append(e)
    tblPr.append(b)


def cell_margins(table, top=60, bottom=60, left=100, right=100):
    tblPr = table._tbl.tblPr
    m = OxmlElement("w:tblCellMar")
    for side, v in (("top", top), ("left", left), ("bottom", bottom), ("right", right)):
        e = OxmlElement(f"w:{side}")
        e.set(qn("w:w"), str(v))
        e.set(qn("w:type"), "dxa")
        m.append(e)
    tblPr.append(m)


def widths(table, inches):
    table.autofit = False
    # The DocGen renderer sizes columns from the table grid, not the cell widths.
    for col, w in zip(table._tbl.tblGrid.findall(qn("w:gridCol")), inches):
        col.set(qn("w:w"), str(int(w * 1440)))
    for row in table.rows:
        for cell, w in zip(row.cells, inches):
            cell.width = Inches(w)


def run(p, text, size=None, bold=False, color=None, italic=False, caps=False):
    r = p.add_run(text)
    if size:
        r.font.size = Pt(size)
    r.bold = bold
    r.italic = italic
    r.font.all_caps = caps
    if color:
        r.font.color.rgb = RGBColor.from_string(color)
    return r


def para(container, text="", size=None, bold=False, color=None, align=None, before=0, after=0):
    p = container.add_paragraph()
    p.paragraph_format.space_before = Pt(before)
    p.paragraph_format.space_after = Pt(after)
    if align:
        p.alignment = align
    if text:
        run(p, text, size, bold, color)
    return p


def cell_text(cell, text, size=None, bold=False, color=None, align=None):
    p = cell.paragraphs[0]
    if align:
        p.alignment = align
    run(p, text, size, bold, color)
    return p


def section_title(doc, text, before=14):
    p = para(doc, before=before, after=4)
    run(p, text, 11, True, NAVY, caps=True)
    pPr = p._p.get_or_add_pPr()
    bdr = OxmlElement("w:pBdr")
    bottom = OxmlElement("w:bottom")
    bottom.set(qn("w:val"), "single")
    bottom.set(qn("w:sz"), "8")
    bottom.set(qn("w:space"), "2")
    bottom.set(qn("w:color"), GLACIER)
    bdr.append(bottom)
    pPr.append(bdr)


def header_band(doc, title, subtitle, footer_text):
    sec = doc.sections[0]
    header = sec.header
    hp = header.paragraphs[0]
    ht = header.add_table(rows=1, cols=2, width=Inches(CONTENT_W))
    borders(ht)
    cell_margins(ht, 140, 140, 180, 180)
    widths(ht, [3.0, 4.3])
    for c in ht.rows[0].cells:
        shade(c, NAVY)
        c.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
    ht.cell(0, 0).paragraphs[0].add_run().add_picture(LOGO_WHITE, width=Inches(1.9))
    rc = ht.cell(0, 1)
    cell_text(rc, title, 14, True, "FFFFFF", RIGHT)
    p = rc.add_paragraph()
    p.alignment = RIGHT
    run(p, subtitle, 8.5, False, "FFFFFF")
    hp._p.getparent().remove(hp._p)
    header.add_paragraph()
    fp = sec.footer.paragraphs[0]
    fp.alignment = WD_ALIGN_PARAGRAPH.CENTER
    run(fp, "Brightline Commercial", 8, True, NAVY)
    run(fp, "   |   " + footer_text, 8, False, GREY)


def info_blocks(doc, blocks):
    """A tinted row of labelled address and contact blocks: [(label, [lines])]."""
    info = doc.add_table(rows=2, cols=len(blocks))
    borders(info)
    cell_margins(info, 50, 50, 120, 120)
    widths(info, [CONTENT_W / len(blocks)] * len(blocks))
    for i, (label, lines) in enumerate(blocks):
        c = info.cell(0, i)
        shade(c, TINT)
        cell_text(c, label, 7.5, True, NAVY)
        c = info.cell(1, i)
        shade(c, TINT)
        for j, line in enumerate(lines):
            p = c.paragraphs[0] if j == 0 else c.add_paragraph()
            run(p, line, 9.5 if j == 0 else 8.5, j == 0, INK)


def loop_table(doc, headers, col_widths, row, loop, right_from, total=None):
    """A table with a header row, one {{#loop}} row and an optional tinted total row.

    row: [(token, size, bold, color)] per column. total: (label, token) spanning the first columns.
    """
    rows = 3 if total else 2
    t = doc.add_table(rows=rows, cols=len(headers))
    borders(t, RULE, inside_h=True)
    cell_margins(t, 70, 70, 110, 110)
    widths(t, col_widths)
    for i, h in enumerate(headers):
        c = t.cell(0, i)
        shade(c, INK)
        cell_text(c, h, 8, True, "FFFFFF", RIGHT if i >= right_from else None)
    last = len(row) - 1
    for i, (token, size, bold, color) in enumerate(row):
        text = token
        if i == 0:
            text = "{{#" + loop + "}}" + text
        if i == last:
            text = text + "{{/" + loop + "}}"
        cell_text(t.cell(1, i), text, size, bold, color, RIGHT if i >= right_from else None)
    if total:
        label, token = total
        cells = t.rows[2].cells
        merged = cells[0]
        for c in cells[1:-1]:
            merged = merged.merge(c)
        for c in (merged, cells[-1]):
            shade(c, TINT)
        cell_text(merged, label, 10, True, INK)
        cell_text(cells[-1], token, 10.5, True, NAVY, RIGHT)
    return t


def band(doc, values):
    para(doc, after=8)
    b = doc.add_table(rows=1, cols=len(values))
    borders(b)
    cell_margins(b, 110, 110, 160, 160)
    widths(b, [CONTENT_W / len(values)] * len(values))
    for i, (label, value) in enumerate(values):
        c = b.cell(0, i)
        shade(c, NAVY)
        cell_text(c, label, 7.5, True, "FFFFFF", WD_ALIGN_PARAGRAPH.CENTER)
        p = c.add_paragraph()
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        run(p, value, 15, True, "FFFFFF")


def numbered_steps(doc, steps):
    st = doc.add_table(rows=len(steps), cols=2)
    borders(st)
    cell_margins(st, 60, 60, 100, 100)
    widths(st, [0.45, 6.85])
    for r, (num, title, body) in enumerate(steps):
        n = st.cell(r, 0)
        shade(n, NAVY)
        n.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
        cell_text(n, num, 13, True, "FFFFFF", WD_ALIGN_PARAGRAPH.CENTER)
        c = st.cell(r, 1)
        cell_text(c, title, 10, True, INK)
        p = c.add_paragraph()
        run(p, body, 9, False, GREY)


def bullets(doc, lines, color=GREY, size=8.5):
    for line in lines:
        p = para(doc, after=2)
        run(p, "•  ", size, True, color)
        run(p, line, size, False, color)


def acceptance(doc, text, who):
    section_title(doc, "Acceptance", before=16)
    para(doc, text, 8.5, color=GREY, after=10)
    sig = doc.add_table(rows=2, cols=2)
    borders(sig)
    cell_margins(sig, 40, 40, 0, 200)
    widths(sig, [3.65, 3.65])
    for i, (label, name) in enumerate(who):
        c = sig.cell(0, i)
        cell_text(c, " ", 18)
        pPr = c.paragraphs[0]._p.get_or_add_pPr()
        bdr = OxmlElement("w:pBdr")
        b = OxmlElement("w:bottom")
        b.set(qn("w:val"), "single")
        b.set(qn("w:sz"), "6")
        b.set(qn("w:color"), INK)
        bdr.append(b)
        pPr.append(bdr)
        c2 = sig.cell(1, i)
        cell_text(c2, label, 8, True, INK)
        run(c2.add_paragraph(), name, 8.5, False, GREY)
        run(c2.add_paragraph(), "Name, title and date: ____________________", 8.5, False, GREY)


def prepared_for(doc, line):
    p = para(doc, before=2)
    run(p, "Prepared for ", 18, False, GREY)
    run(p, "{{AccountName}}", 18, True, INK)
    p = para(doc, before=2, after=8)
    run(p, line, 9, False, GREY)


def contract_proposal():
    doc = new_doc()
    header_band(doc, "Planned Maintenance Proposal", "Proposal {{QuoteNumber}}   |   Prepared {{CreatedDate}}",
                "Proposal {{QuoteNumber}}   |   Questions? Contact {{SalesRep}} at {{SalesRepEmail}}")
    prepared_for(doc, "Proposal {{QuoteNumber}}   ·   Prepared {{CreatedDate}}   ·   Valid until {{ExpirationDate}}")
    info_blocks(doc, [
        ("BILL TO (HEADQUARTERS)", ["{{AccountName}}", "{{BillingStreet}}",
                                    "{{BillingCity}}, {{BillingState}} {{BillingPostalCode}}"]),
        ("FACILITIES CONTACT", ["{{ContactName}}", "{{ContactEmail}}", "{{ContactPhone}}"]),
        ("YOUR ACCOUNT MANAGER", ["{{SalesRep}}", "{{SalesRepEmail}}"]),
    ])

    section_title(doc, "Your Sites")
    para(doc, "Every site is priced from the rooftop units on it: a quarterly maintenance rate by unit size, filter "
         "changes at each visit and the response time the site needs. Restaurants and the data room get 4-hour "
         "response around the clock; offices get next business day.", 8.5, color=GREY, after=6)
    loop_table(doc, ["SITE", "UNITS AND RESPONSE", "PER YEAR"], [2.4, 3.5, 1.4],
               [("{{Name}}", 10, True, INK), ("{{Coverage}}", 9, False, GREY), ("{{Annual}}", 10, True, INK)],
               "Site", 2, total=("Contract total for {{TermMonths}} months", "{{ContractTotal}}"))

    band(doc, [("CONTRACT TERM", "{{TermMonths}} months"), ("MONTHLY INVOICE", "{{Installment}}"),
               ("CONTRACT TOTAL", "{{ContractTotal}}")])

    section_title(doc, "What Each Site Gets", before=16)
    para(doc, "The services behind each site's price, with the rooftop units they cover.", 8.5, color=GREY, after=2)
    # One block per site: the site name, then a table of its lines (a loop nested in the site loop).
    p = para(doc, before=8, after=3)
    run(p, "{{#Site}}{{Name}}", 10, True, NAVY)
    run(p, "   {{Annual}} per year", 9, False, GREY)
    loop_table(doc, ["SERVICE", "UNITS COVERED", "QTY", "PER YEAR"], [2.6, 3.2, 0.5, 1.0],
               [("{{Name}}", 8.5, False, INK), ("{{Units}}", 8, False, GREY),
                ("{{Quantity}}", 8.5, False, INK), ("{{Annual}}", 8.5, True, INK)], "Line", 2)
    # The closing tag's paragraph merges into the next site's heading, so it carries the heading style.
    p = para(doc, before=8, after=3)
    run(p, "{{/Site}}", 10, True, NAVY)

    section_title(doc, "How the Contract Works", before=16)
    numbered_steps(doc, [
        ("1", "Quarterly maintenance at every site",
         "Each rooftop unit gets a planned maintenance visit every quarter: coils, belts, electrical checks, "
         "refrigerant readings and a filter change. Visits are scheduled with your facilities contact."),
        ("2", "Response coverage by site",
         "When a unit goes down, the site's response tier applies: 4 hours, 24/7 at restaurants and the data "
         "room, next business day at offices. Labor on covered calls is included."),
        ("3", "One invoice to headquarters",
         "Every month, one consolidated invoice goes to accounts payable with a subtotal for each site and your "
         "PO number, so each site's cost is easy to allocate."),
        ("4", "Refrigerant compliance",
         "Units holding 50 lb or more of refrigerant have every addition logged and their leak rate tracked. A "
         "unit over the limit gets a leak repair scheduled within 30 days."),
    ])

    section_title(doc, "Contract Terms", before=16)
    bullets(doc, [
        "The contract runs {{TermMonths}} months from the start of service and renews yearly, with a price "
        "increase of 3% at each renewal.",
        "Invoices are issued monthly in advance on Net 30 terms and reference your purchase order number.",
        "Sites and units can be added during the term; the added site is billed from its start date to the end "
        "of the term.",
        "Equipment replacement, parts and refrigerant are not included and are quoted separately.",
        "Pricing in this proposal is valid until {{ExpirationDate}}.",
    ])
    acceptance(doc, "By signing below, you accept this proposal and authorize Brightline Commercial to begin "
               "planned maintenance at the sites listed above.",
               [("Authorized signer, {{AccountName}}", "{{ContactName}}"), ("Brightline Commercial", "{{SalesRep}}")])
    return doc


def project_proposal():
    doc = new_doc()
    header_band(doc, "Capital Project Proposal", "Proposal {{QuoteNumber}}   |   Prepared {{CreatedDate}}",
                "Proposal {{QuoteNumber}}   |   Questions? Contact {{SalesRep}} at {{SalesRepEmail}}")
    prepared_for(doc, "{{ProjectName}}   ·   Prepared {{CreatedDate}}   ·   Valid until {{ExpirationDate}}")
    info_blocks(doc, [
        ("PROJECT SITE", ["{{SiteStreet}}", "{{SiteCity}}, {{SiteState}} {{SitePostalCode}}"]),
        ("FACILITIES CONTACT", ["{{ContactName}}", "{{ContactEmail}}", "{{ContactPhone}}"]),
        ("YOUR PROJECT MANAGER", ["{{SalesRep}}", "{{SalesRepEmail}}"]),
    ])

    section_title(doc, "Project Scope")
    scope = doc.add_table(rows=1, cols=1)
    borders(scope, TINT)
    cell_margins(scope, 110, 110, 160, 160)
    widths(scope, [CONTENT_W])
    shade(scope.cell(0, 0), TINT)
    cell_text(scope.cell(0, 0), "{{Scope}}", 10, False, INK)

    section_title(doc, "Project Price")
    para(doc, "New high-efficiency rooftop units on R-454B refrigerant, installed on the existing curbs, with the crane "
         "lift, refrigerant recovery from the old units, start-up and commissioning.", 8.5, color=GREY, after=6)
    loop_table(doc, ["ITEM", "DETAILS", "QTY", "UNIT PRICE", "PRICE"], [1.95, 2.45, 0.45, 1.15, 1.3],
               [("{{Name}}", 10, True, INK), ("{{Detail}}", 8.5, False, GREY), ("{{Quantity}}", 10, False, INK),
                ("{{UnitPrice}}", 9.5, False, INK), ("{{Price}}", 10, True, INK)],
               "Line", 2, total=("Project total", "{{ProjectTotal}}"))

    section_title(doc, "Milestone Billing", before=16)
    para(doc, "The project is billed in three milestones. Each invoice references your purchase order number.",
         8.5, color=GREY, after=6)
    ms = doc.add_table(rows=5, cols=4)
    borders(ms, RULE, inside_h=True)
    cell_margins(ms, 70, 70, 110, 110)
    widths(ms, [1.7, 3.5, 0.7, 1.4])
    for i, h in enumerate(["MILESTONE", "BILLED WHEN", "SHARE", "AMOUNT"]):
        c = ms.cell(0, i)
        shade(c, INK)
        cell_text(c, h, 8, True, "FFFFFF", RIGHT if i >= 2 else None)
    for r, (name, when, share, token) in enumerate([
        ("Deposit", "The project is booked with your PO", "40%", "{{Deposit}}"),
        ("Installation", "The new units are installed and running", "40%", "{{Install}}"),
        ("Commissioning", "Start-up and commissioning are complete and the site is handed over", "20%",
         "{{Commissioning}}"),
    ], start=1):
        cell_text(ms.cell(r, 0), name, 10, True, INK)
        cell_text(ms.cell(r, 1), when, 9, False, GREY)
        cell_text(ms.cell(r, 2), share, 10, True, EMBER, RIGHT)
        cell_text(ms.cell(r, 3), token, 10, True, INK, RIGHT)
    tot = ms.rows[4].cells
    merged = tot[0].merge(tot[1]).merge(tot[2])
    for c in (merged, tot[3]):
        shade(c, TINT)
    cell_text(merged, "Project total", 10, True, INK)
    cell_text(tot[3], "{{ProjectTotal}}", 10.5, True, NAVY, RIGHT)

    band(doc, [("DUE AT BOOKING", "{{Deposit}}"), ("AT INSTALLATION", "{{Install}}"),
               ("AT COMMISSIONING", "{{Commissioning}}")])

    section_title(doc, "How the Project Runs", before=16)
    numbered_steps(doc, [
        ("1", "Crane lift",
         "We schedule the crane and rigging crew with your facilities contact, then lift the new units onto the "
         "roof and the old units off."),
        ("2", "Installation",
         "EPA 608 certified technicians recover the refrigerant from the old units, set the new units on the "
         "existing curbs and connect them. Completing the installation bills the second milestone."),
        ("3", "Commissioning and handover",
         "We start up and commission each unit, record the readings and hand the site over. The final 20% is "
         "billed then, and the new units join your maintenance contract."),
    ])

    section_title(doc, "Project Terms", before=16)
    bullets(doc, [
        "Pricing assumes the existing curbs, electrical service and gas supply can be reused. Curb adapters, "
        "structural work and electrical upgrades are quoted separately if needed.",
        "Milestone invoices are due on Net 30 terms.",
        "Manufacturer warranties are registered for you at commissioning.",
        "Pricing in this proposal is valid until {{ExpirationDate}}.",
    ])
    acceptance(doc, "By signing below, you accept this proposal and authorize Brightline Commercial to schedule the "
               "project at the site above.",
               [("Authorized signer, {{AccountName}}", "{{ContactName}}"), ("Brightline Commercial", "{{SalesRep}}")])
    return doc


def consolidated_invoice():
    doc = new_doc()
    header_band(doc, "Invoice", "Invoice {{DocumentNumber}}   |   Dated {{InvoiceDate}}",
                "Invoice {{DocumentNumber}}   |   PO {{PoNumber}}   |   billing@brightline.example")
    p = para(doc, before=2)
    run(p, "Invoice for ", 18, False, GREY)
    run(p, "{{AccountName}}", 18, True, INK)
    p = para(doc, before=2, after=8)
    run(p, "Invoice {{DocumentNumber}}   ·   Dated {{InvoiceDate}}   ·   Due {{DueDate}}", 9, False, GREY)
    info_blocks(doc, [
        ("BILL TO", ["{{AccountName}}", "{{BillingStreet}}", "{{BillingCity}}, {{BillingState}} {{BillingPostalCode}}"]),
        ("ATTENTION", ["{{BillTo}}", "{{BillToEmail}}"]),
        ("PURCHASE ORDER", ["{{PoNumber}}", "Due {{DueDate}}"]),
    ])

    band(doc, [("CHARGES", "{{InvoiceCharge}}"), ("TAX", "{{InvoiceTax}}"), ("AMOUNT DUE", "{{Balance}}")])

    section_title(doc, "Charges by Site", before=16)
    para(doc, "One invoice for all of your sites. Each site's subtotal is shown separately so it can be allocated "
         "to that site's budget.", 8.5, color=GREY, after=6)
    t = loop_table(doc, ["SITE", "SERVICES", "CHARGES", "TAX", "TOTAL"], [1.85, 2.75, 0.9, 0.75, 1.05],
                   [("{{Name}}", 9.5, True, INK), ("{{Services}}", 8, False, GREY), ("{{Charge}}", 9, False, INK),
                    ("{{Tax}}", 9, False, INK), ("{{Total}}", 9.5, True, INK)], "Site", 2,
                   total=("Invoice total", "{{InvoiceTotal}}"))
    # The site's coverage and service period sit under its name.
    name_cell = t.cell(1, 0)
    p = name_cell.add_paragraph()
    run(p, "{{Coverage}}", 8, False, GREY)
    p = name_cell.add_paragraph()
    run(p, "{{Period}}", 8, False, GREY)

    section_title(doc, "How to Pay", before=16)
    bullets(doc, [
        "Payment is due by {{DueDate}}. Please include invoice {{DocumentNumber}} and PO {{PoNumber}} with your "
        "payment.",
        "ACH: Brightline Commercial, routing 000000000, account ending 0000 (demo details).",
        "Questions about a site's charges? Reply to this invoice or contact billing@brightline.example.",
    ])
    return doc


TEMPLATES = [
    ("RLM_HVAC_Contract_Proposal_1.dt", contract_proposal),
    ("RLM_HVAC_Project_Proposal_1.dt", project_proposal),
    ("RLM_HVAC_Commercial_Invoice_1.dt", consolidated_invoice),
]

os.makedirs(OUT_DIR, exist_ok=True)
for name, build in TEMPLATES:
    path = os.path.join(OUT_DIR, name)
    build().save(path)
    print("saved", path)
