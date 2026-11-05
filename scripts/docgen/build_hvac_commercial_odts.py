"""Generate the Brightline Commercial OmniDataTransforms (extract + pass-through transform) and the
DocumentTemplate metadata for the contract proposal, the capital project proposal and the
consolidated invoice.

Usage:
    python scripts/docgen/build_hvac_commercial_odts.py unpackaged/post_hvac_commercial_docgen

Output keys must match the tokens in build_hvac_commercial_docs.py. Writes omniDataTransforms/*.rpt-meta.xml
and documentTemplates/*.dt-meta.xml (the tokenList comes from the mappings below).
"""
import json
import os
import sys
import uuid
from xml.sax.saxutils import escape

OUT = sys.argv[1]
DATE = "Date(MM/dd/yyyy)"

CONTRACT = {
    "template": "RLM_HVAC_Contract_Proposal",
    "usage": "Revenue_Lifecycle_Management",
    "extract": "RLMHVACContractProposalExtract",
    "transform": "RLMHVACContractProposalTransform",
    "target": "Brightline_Contract_Proposal(Version 1)",
    "input": {"Id": "0Q0Ka000000EXAMPLE"},
    # (seq, object, inputField, operator, filterValue, outputPath)
    "queries": [
        (1, "Quote", "Id", "=", "Id", "Quote"),
        (2, "Account", "Id", "=", "Quote:AccountId", "Account"),
        (3, "User", "Id", "=", "Quote:CreatedById", "SalesRep"),
        (4, "Contact", "Id", "=", "Quote:ContactId", "Contact"),
        # Groups come back in creation order, which is site order. Each site carries its own lines.
        (5, "QuoteLineGroup", "QuoteId", "=", "Quote:Id", "Quote:Site"),
        (6, "QuoteLineItem", "QuoteLineGroupId", "=", "Quote:Site:Id", "Quote:Site:Line"),
        (7, "Product2", "Id", "=", "Quote:Site:Line:Product2Id", "Quote:Site:Line:Product"),
    ],
    # (inputField, outputField, format)
    "mappings": [
        ("Quote:QuoteNumber", "QuoteNumber", "String"),
        ("Quote:CreatedDate", "CreatedDate", DATE),
        ("Quote:ExpirationDate", "ExpirationDate", DATE),
        ("Account:Name", "AccountName", "String"),
        ("Quote:BillingStreet", "BillingStreet", "String"),
        ("Quote:BillingCity", "BillingCity", "String"),
        ("Quote:BillingState", "BillingState", "String"),
        ("Quote:BillingPostalCode", "BillingPostalCode", "String"),
        ("Contact:Name", "ContactName", "String"),
        ("Contact:Email", "ContactEmail", "String"),
        ("Contact:Phone", "ContactPhone", "String"),
        ("SalesRep:Name", "SalesRep", "String"),
        ("SalesRep:Email", "SalesRepEmail", "String"),
        ("Quote:RLM_TermMonths__c", "TermMonths", "Integer"),
        # Commercial contract lines are termed, so the recurring roll-up is the term total.
        ("Quote:RLM_HVAC_Monthly_Total__c", "ContractTotal", "Currency"),
        ("Quote:RLM_HVAC_Installment_Amount__c", "Installment", "Currency"),
        ("Quote:Site:Name", "Site:Name", "String"),
        ("Quote:Site:Description", "Site:Coverage", "String"),
        ("Quote:Site:SummarySubtotal", "Site:Annual", "Currency"),
        ("Quote:Site:Line:Product:Name", "Site:Line:Name", "String"),
        ("Quote:Site:Line:Description", "Site:Line:Units", "String"),
        ("Quote:Site:Line:Quantity", "Site:Line:Quantity", "Integer"),
        ("Quote:Site:Line:NetTotalPrice", "Site:Line:Annual", "Currency"),
    ],
    "sample": {
        "QuoteNumber": "00000068", "CreatedDate": "11/05/2026", "ExpirationDate": "12/05/2026",
        "AccountName": "Lakeshore Property Group", "BillingStreet": "1 Lakeshore Plaza", "BillingCity": "Naperville",
        "BillingState": "IL", "BillingPostalCode": "60563", "ContactName": "Renee Castillo",
        "ContactEmail": "facilities@example.com", "ContactPhone": "(630) 555-0142", "SalesRep": "Sample Account Manager",
        "SalesRepEmail": "manager@example.com", "TermMonths": 12, "ContractTotal": "$44,582.40",
        "Installment": "$3,715.20",
        "Site": [
            {"Name": "Ember & Oak Bistro", "Coverage": "4 units, 32.5 tons, 4 hours, 24/7 response", "Annual": "$4,824.60",
             "Line": [{"Name": "Planned Maintenance, 6 to 12 tons", "Units": "RTU-02, RTU-03, RTU-04", "Quantity": 3,
                       "Annual": "$1,881.00"}]},
        ],
    },
}

PROJECT = {
    "template": "RLM_HVAC_Project_Proposal",
    "usage": "Revenue_Lifecycle_Management",
    "extract": "RLMHVACProjectProposalExtract",
    "transform": "RLMHVACProjectProposalTransform",
    "target": "Brightline_Project_Proposal(Version 1)",
    "input": {"Id": "0Q0Ka000000EXAMPLE"},
    "queries": [
        (1, "Quote", "Id", "=", "Id", "Quote"),
        (2, "Account", "Id", "=", "Quote:AccountId", "Account"),
        (3, "User", "Id", "=", "Quote:CreatedById", "SalesRep"),
        (4, "Contact", "Id", "=", "Quote:ContactId", "Contact"),
        (5, "QuoteLineItem", "QuoteId", "=", "Quote:Id", "Quote:Line"),
        (6, "Product2", "Id", "=", "Quote:Line:Product2Id", "Quote:Line:Product"),
    ],
    "mappings": [
        ("Quote:QuoteNumber", "QuoteNumber", "String"),
        ("Quote:Name", "ProjectName", "String"),
        ("Quote:CreatedDate", "CreatedDate", DATE),
        ("Quote:ExpirationDate", "ExpirationDate", DATE),
        ("Account:Name", "AccountName", "String"),
        ("Quote:ShippingStreet", "SiteStreet", "String"),
        ("Quote:ShippingCity", "SiteCity", "String"),
        ("Quote:ShippingState", "SiteState", "String"),
        ("Quote:ShippingPostalCode", "SitePostalCode", "String"),
        ("Contact:Name", "ContactName", "String"),
        ("Contact:Email", "ContactEmail", "String"),
        ("Contact:Phone", "ContactPhone", "String"),
        ("SalesRep:Name", "SalesRep", "String"),
        ("SalesRep:Email", "SalesRepEmail", "String"),
        ("Quote:Description", "Scope", "String"),
        ("Quote:TotalPrice", "ProjectTotal", "Currency"),
        ("Quote:RLM_HVAC_Deposit_Amount__c", "Deposit", "Currency"),
        ("Quote:RLM_HVAC_Install_Amount__c", "Install", "Currency"),
        ("Quote:RLM_HVAC_Commissioning_Amount__c", "Commissioning", "Currency"),
        ("Quote:Line:Product:Name", "Line:Name", "String"),
        ("Quote:Line:Description", "Line:Detail", "String"),
        ("Quote:Line:Quantity", "Line:Quantity", "Integer"),
        ("Quote:Line:UnitPrice", "Line:UnitPrice", "Currency"),
        ("Quote:Line:NetTotalPrice", "Line:Price", "Currency"),
    ],
    "sample": {
        "QuoteNumber": "00000084", "ProjectName": "Lakeshore Office Park A - Rooftop Unit Replacement",
        "CreatedDate": "11/05/2026", "ExpirationDate": "12/05/2026", "AccountName": "Lakeshore Property Group",
        "SiteStreet": "1800 Corporate Way", "SiteCity": "Naperville", "SiteState": "IL", "SitePostalCode": "60563",
        "ContactName": "Renee Castillo", "ContactEmail": "facilities@example.com", "ContactPhone": "(630) 555-0142",
        "SalesRep": "Sample Project Manager", "SalesRepEmail": "manager@example.com",
        "Scope": "6 rooftop units replaced at Lakeshore Office Park A: RTU-01 to RTU-06.",
        "ProjectTotal": "$103,400.00", "Deposit": "$41,360.00", "Install": "$41,360.00", "Commissioning": "$20,680.00",
        "Line": [
            {"Name": "Rooftop Unit Replacement, 10 tons", "Detail": "RTU-01, RTU-02, RTU-03, RTU-04, RTU-05, RTU-06",
             "Quantity": 6, "UnitPrice": "$16,800.00", "Price": "$100,800.00"},
            {"Name": "Crane Lift", "Detail": "Install day at Lakeshore Office Park A", "Quantity": 1,
             "UnitPrice": "$2,600.00", "Price": "$2,600.00"},
        ],
    },
}

INVOICE = {
    "template": "RLM_HVAC_Commercial_Invoice",
    "usage": "Revenue_Lifecycle_Management",
    "extract": "RLMHVACCommercialInvoiceExtract",
    "transform": "RLMHVACCommercialInvoiceTransform",
    "target": "Brightline_Commercial_Invoice(Version 1)",
    "input": {"Id": "3ttKa000000EXAMPLE"},
    "queries": [
        (1, "Invoice", "Id", "=", "Id", "Invoice"),
        (2, "Account", "Id", "=", "Invoice:BillingAccountId", "Account"),
        (3, "Contact", "Id", "=", "Invoice:BillToContactId", "Contact"),
        (4, "RLM_HVAC_Invoice_Site__c", "RLM_HVAC_Invoice__c", "=", "Invoice:Id", "Invoice:Site"),
    ],
    "mappings": [
        ("Invoice:DocumentNumber", "DocumentNumber", "String"),
        ("Invoice:InvoiceDate", "InvoiceDate", DATE),
        ("Invoice:DueDate", "DueDate", DATE),
        ("Invoice:RLM_HVAC_PO_Number__c", "PoNumber", "String"),
        ("Invoice:TotalAmount", "InvoiceCharge", "Currency"),
        ("Invoice:TotalTaxAmount", "InvoiceTax", "Currency"),
        ("Invoice:TotalAmountWithTax", "InvoiceTotal", "Currency"),
        ("Invoice:Balance", "Balance", "Currency"),
        ("Account:Name", "AccountName", "String"),
        ("Account:BillingStreet", "BillingStreet", "String"),
        ("Account:BillingCity", "BillingCity", "String"),
        ("Account:BillingState", "BillingState", "String"),
        ("Account:BillingPostalCode", "BillingPostalCode", "String"),
        ("Contact:Name", "BillTo", "String"),
        ("Contact:Email", "BillToEmail", "String"),
        ("Invoice:Site:Name", "Site:Name", "String"),
        ("Invoice:Site:RLM_HVAC_Coverage__c", "Site:Coverage", "String"),
        ("Invoice:Site:RLM_HVAC_Period__c", "Site:Period", "String"),
        ("Invoice:Site:RLM_HVAC_Services__c", "Site:Services", "String"),
        ("Invoice:Site:RLM_HVAC_Charge__c", "Site:Charge", "Currency"),
        ("Invoice:Site:RLM_HVAC_Tax__c", "Site:Tax", "Currency"),
        ("Invoice:Site:RLM_HVAC_Total__c", "Site:Total", "Currency"),
    ],
    "sample": {
        "DocumentNumber": "DOC-000000007", "InvoiceDate": "11/05/2026", "DueDate": "12/05/2026",
        "PoNumber": "LPG-PO-2026-118", "InvoiceCharge": "$4,212.00", "InvoiceTax": "$339.13", "InvoiceTotal": "$4,551.13",
        "Balance": "$4,551.13", "AccountName": "Lakeshore Property Group", "BillingStreet": "1 Lakeshore Plaza",
        "BillingCity": "Naperville", "BillingState": "IL", "BillingPostalCode": "60563", "BillTo": "Accounts Payable",
        "BillToEmail": "ap@example.com",
        "Site": [
            {"Name": "Ember & Oak Bistro", "Coverage": "Restaurant · 4 hours response",
             "Period": "Dec 1, 2026 – Dec 31, 2026",
             "Services": "Filter Program (4); Planned Maintenance, 6 to 12 tons (3)", "Charge": "$402.05",
             "Tax": "$32.37", "Total": "$434.42"},
        ],
    },
}

VARIANTS = [CONTRACT, PROJECT, INVOICE]


def key(namespace, name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"{namespace}/{name}"))


def item(fields):
    lines = ["    <omniDataTransformItem>"]
    for k in sorted(fields):
        lines.append(f"        <{k}>{escape(str(fields[k]), {chr(39): '&apos;'})}</{k}>")
    lines.append("    </omniDataTransformItem>")
    return "\n".join(lines)


def common(name, gk):
    return {
        "disabled": "false",
        "filterGroup": "0.0",
        "globalKey": gk,
        "linkedObjectSequence": "0.0",
        "name": name,
        "requiredForUpsert": "false",
        "upsertKey": "false",
    }


def odt(name, dtype, items, preview, expected=None, target=None):
    head = f"""<?xml version="1.0" encoding="UTF-8"?>
<OmniDataTransform xmlns="http://soap.sforce.com/2006/04/metadata">
    <active>false</active>
    <assignmentRulesUsed>false</assignmentRulesUsed>
    <deletedOnSuccess>false</deletedOnSuccess>
    <errorIgnored>false</errorIgnored>
"""
    if expected is not None:
        head += f"    <expectedOutputJson>{escape(json.dumps(expected, indent=2))}</expectedOutputJson>\n"
    head += f"""    <fieldLevelSecurityEnabled>false</fieldLevelSecurityEnabled>
    <inputType>JSON</inputType>
    <isManagedUsingStdDesigner>false</isManagedUsingStdDesigner>
    <name>{name}</name>
    <nullInputsIncludedInOutput>false</nullInputsIncludedInOutput>
"""
    tail = f"""    <outputType>JSON</outputType>
    <previewJsonData>{escape(json.dumps(preview, indent=2))}</previewJsonData>
    <processSuperBulk>false</processSuperBulk>
    <responseCacheTtlMinutes>0.0</responseCacheTtlMinutes>
    <rollbackOnError>false</rollbackOnError>
    <sourceObjectDefault>false</sourceObjectDefault>
    <synchronousProcessThreshold>0.0</synchronousProcessThreshold>
"""
    if target:
        tail += f"    <targetOutputFileName>{target}</targetOutputFileName>\n"
    tail += f"""    <type>{dtype}</type>
    <uniqueName>{name}_1</uniqueName>
    <versionNumber>1.0</versionNumber>
    <xmlDeclarationRemoved>false</xmlDeclarationRemoved>
</OmniDataTransform>
"""
    return head + "\n".join(items) + "\n" + tail


def build_extract(v):
    name = v["extract"]
    items = []
    for seq, obj, field, op, value, out in v["queries"]:
        f = common(name, key(name, f"q/{seq}/{field}/{op}"))
        f.update({
            "filterOperator": op,
            "filterValue": value,
            "inputFieldName": field,
            "inputObjectName": obj,
            "inputObjectQuerySequence": f"{seq}.0",
            "outputCreationSequence": "0.0",
            "outputFieldName": out,
            "outputObjectName": "json",
        })
        items.append(item(f))
    for src, out, fmt in v["mappings"]:
        f = common(name, key(name, f"m/{out}"))
        f.update({
            "inputFieldName": src,
            "inputObjectQuerySequence": "0.0",
            "outputCreationSequence": "1.0",
            "outputFieldFormat": fmt,
            "outputFieldName": out,
            "outputObjectName": "json",
            "transformValuesMappings": "{ }",
        })
        items.append(item(f))
    return odt(name, "Extract", items, v["input"])


def build_transform(v):
    name = v["transform"]
    items = []
    for _, out, _ in v["mappings"]:
        f = common(name, key(name, f"t/{out}"))
        f.update({
            "inputFieldName": out,
            "inputObjectQuerySequence": "0.0",
            "outputCreationSequence": "1.0",
            "outputFieldName": out,
            "outputObjectName": "json",
            "transformValuesMappings": "{ }",
        })
        items.append(item(f))
    return odt(name, "Transform", items, v["sample"], expected=v["sample"], target=v["target"])


def build_template_meta(v):
    tokens = ",".join(out for _, out, _ in v["mappings"])
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<DocumentTemplate xmlns="http://soap.sforce.com/2006/04/metadata">
    <documentGenerationMechanism>ServerSide</documentGenerationMechanism>
    <extractOmniDataTransformName>{v["extract"]}</extractOmniDataTransformName>
    <fileExtension>docx</fileExtension>
    <hasBatchableSection>false</hasBatchableSection>
    <isActive>true</isActive>
    <isSectionProcessed>false</isSectionProcessed>
    <mapperOmniDataTransformName>{v["transform"]}</mapperOmniDataTransformName>
    <name>{v["template"]}</name>
    <shouldDisplayUnmappedToken>false</shouldDisplayUnmappedToken>
    <shouldExtractEmbeddedTmplToken>false</shouldExtractEmbeddedTmplToken>
    <status>Active</status>
    <tokenList>{tokens}</tokenList>
    <tokenMappingMethodType>OmniDataTransform</tokenMappingMethodType>
    <tokenMappingType>JSON</tokenMappingType>
    <type>MicrosoftWord</type>
    <uniqueName>{v["template"]}_1</uniqueName>
    <usageType>{v["usage"]}</usageType>
    <versionNumber>1</versionNumber>
</DocumentTemplate>
"""


odt_dir = os.path.join(OUT, "omniDataTransforms")
dt_dir = os.path.join(OUT, "documentTemplates")
os.makedirs(odt_dir, exist_ok=True)
os.makedirs(dt_dir, exist_ok=True)
for v in VARIANTS:
    for name, body in [(v["extract"], build_extract(v)), (v["transform"], build_transform(v))]:
        with open(os.path.join(odt_dir, f"{name}_1.rpt-meta.xml"), "w", encoding="utf-8") as fh:
            fh.write(body)
    with open(os.path.join(dt_dir, f"{v['template']}_1.dt-meta.xml"), "w", encoding="utf-8") as fh:
        fh.write(build_template_meta(v))
print("wrote", OUT)
