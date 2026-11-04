"""Generate the Brightline HVAC proposal OmniDataTransforms (extract + pass-through transform) for the
agreement proposal and the system replacement proposal.

Usage:
    python scripts/docgen/build_hvac_proposal_odts.py unpackaged/post_hvac_docgen/omniDataTransforms

Output keys must match the tokens in build_hvac_proposal.py and the template's tokenList.
"""
import json
import os
import sys
import uuid
from xml.sax.saxutils import escape

OUT = sys.argv[1]
EXTRACT = "RLMHVACProposalExtract"
TRANSFORM = "RLMHVACProposalTransform"

# (seq, object, inputField, operator, filterValue, outputPath)
QUERIES = [
    (1, "Quote", "Id", "=", "Id", "Quote"),
    (2, "Account", "Id", "=", "Quote:AccountId", "Account"),
    (3, "User", "Id", "=", "Quote:CreatedById", "SalesRep"),
    (4, "QuoteLineItem", "QuoteId", "=", "Quote:Id", "Quote:Plan"),
    (4, "QuoteLineItem", "BillingFrequency", "<>", "''", "Quote:Plan"),
    (5, "QuoteLineItem", "QuoteId", "=", "Quote:Id", "Quote:OneTime"),
    (5, "QuoteLineItem", "BillingFrequency", "=", "''", "Quote:OneTime"),
    (6, "Product2", "Id", "=", "Quote:Plan:Product2Id", "Quote:Plan:Product"),
    (7, "Product2", "Id", "=", "Quote:OneTime:Product2Id", "Quote:OneTime:Product"),
    (8, "RLM_HVAC_Finding__c", "Quote_Id__c", "=", "Quote:Id", "Quote:Finding"),
]

DATE = "Date(MM/dd/yyyy)"
# Fills a single row when the quote has no system check findings.
DEFAULTS = {
    "Finding:Equipment": "Whole system",
    "Finding:Observation": "No issues recorded",
}

# (inputField, outputField, format)
MAPPINGS = [
    ("Quote:Id", "QuoteId", "String"),
    ("Quote:QuoteNumber", "QuoteNumber", "String"),
    ("Quote:CreatedDate", "CreatedDate", DATE),
    ("Quote:ExpirationDate", "ExpirationDate", DATE),
    ("Account:Name", "AccountName", "String"),
    ("Account:Phone", "CustomerPhone", "String"),
    ("Quote:BillingStreet", "BillingStreet", "String"),
    ("Quote:BillingCity", "BillingCity", "String"),
    ("Quote:BillingState", "BillingState", "String"),
    ("Quote:BillingPostalCode", "BillingPostalCode", "String"),
    ("Quote:ShippingStreet", "ServiceStreet", "String"),
    ("Quote:ShippingCity", "ServiceCity", "String"),
    ("Quote:ShippingState", "ServiceState", "String"),
    ("Quote:ShippingPostalCode", "ServicePostalCode", "String"),
    ("SalesRep:Name", "SalesRep", "String"),
    ("SalesRep:Email", "SalesRepEmail", "String"),
    ("Quote:RLM_HVAC_Monthly_Total__c", "MonthlyTotal", "Currency"),
    ("Quote:RLM_HVAC_One_Time_Total__c", "OneTimeTotal", "Currency"),
    ("Quote:GrandTotal", "GrandTotal", "Currency"),
    ("Quote:RLM_HVAC_Plan_Explanation__c", "WhyThisPlan", "String"),
    ("Quote:Plan:Product:Name", "Plan:Name", "String"),
    # The quote line's description: the product description plus any equipment age adjustment.
    ("Quote:Plan:Description", "Plan:Description", "String"),
    ("Quote:Plan:Quantity", "Plan:Quantity", "Integer"),
    ("Quote:Plan:NetTotalPrice", "Plan:MonthlyPrice", "Currency"),
    ("Quote:OneTime:Product:Name", "OneTime:Name", "String"),
    ("Quote:OneTime:Product:Description", "OneTime:Description", "String"),
    ("Quote:OneTime:Quantity", "OneTime:Quantity", "Integer"),
    ("Quote:OneTime:NetTotalPrice", "OneTime:Price", "Currency"),
    ("Quote:Finding:Equipment__c", "Finding:Equipment", "String"),
    ("Quote:Finding:Observation__c", "Finding:Observation", "String"),
    ("Quote:Finding:Urgency__c", "Finding:Urgency", "String"),
    ("Quote:Finding:Customer_Note__c", "Finding:Note", "String"),
]

SAMPLE_OUTPUT = {
    "QuoteId": "0Q0Ka000000EXAMPLE",
    "QuoteNumber": "00000052",
    "CreatedDate": "11/02/2026",
    "ExpirationDate": "12/02/2026",
    "AccountName": "Marcus Bell",
    "CustomerPhone": "(630) 555-0187",
    "BillingStreet": "1240 Aurora Ave",
    "BillingCity": "Naperville",
    "BillingState": "IL",
    "BillingPostalCode": "60540",
    "ServiceStreet": "1240 Aurora Ave",
    "ServiceCity": "Naperville",
    "ServiceState": "IL",
    "ServicePostalCode": "60540",
    "SalesRep": "Sample Comfort Advisor",
    "SalesRepEmail": "advisor@example.com",
    "MonthlyTotal": "$70.00",
    "OneTimeTotal": "$507.00",
    "GrandTotal": "$577.00",
    "WhyThisPlan": "We found a worn run capacitor on the outdoor unit and a furnace that is 11 years old. Comfort Plus covers both systems with two tune-ups a year and 8-hour priority response, and we can replace the capacitor today.",
    "Plan": [
        {"Name": "Comfort Plus", "Description": "Basic plus 8-hour priority response, no diagnostic fee and 15% off repairs. Includes a $6.00/mo per system equipment age adjustment (equipment 11\u201315 years old +$6).", "Quantity": 2, "MonthlyPrice": "$70.00"},
    ],
    "OneTime": [
        {"Name": "Initial Tune-up", "Description": "First tune-up for each system at signup.", "Quantity": 2, "Price": "$258.00"},
        {"Name": "Capacitor Replacement", "Description": "Replace a weak or failed run capacitor on the outdoor unit.", "Quantity": 1, "Price": "$185.00"},
        {"Name": "Condensate Drain Clear", "Description": "Clear and flush a clogged condensate drain line and treat the pan.", "Quantity": 1, "Price": "$64.00"},
    ],
    "Finding": [
        {"Equipment": "Outdoor Unit", "Observation": "Capacitor \u2013 Worn", "Urgency": "Repair Soon", "Note": "The run capacitor reads 32 \u00b5F against a 45 \u00b5F rating."},
        {"Equipment": "Furnace", "Observation": "Filter \u2013 Clogged", "Urgency": "Monitor", "Note": "The filter is overdue for a change."},
    ],
}

REPLACEMENT_SAMPLE = {
    **{k: v for k, v in SAMPLE_OUTPUT.items() if k not in ("Plan", "OneTime", "Finding")},
    "MonthlyTotal": "$0.00",
    "OneTimeTotal": "$11,500.00",
    "GrandTotal": "$11,500.00",
    "WhyThisPlan": "The oldest equipment is 18 years old, near the end of its life. We found a cracked furnace heat exchanger "
                   "and an AC low on R-22 refrigerant, which is no longer made.",
    "Plan": [],
    "OneTime": [
        {"Name": "Comfort Plus System", "Description": "Better: 16 SEER2 two-stage heat pump with 96% furnace backup, installed.",
         "Quantity": 1, "Price": "$11,500.00"},
    ],
    "Finding": [
        {"Equipment": "Furnace", "Observation": "Heat Exchanger \u2013 Cracked", "Urgency": "Safety",
         "Note": "The heat exchanger has a crack, which can let carbon monoxide into the home."},
    ],
}

# (extract, transform, field that holds the finding's quote Id, key namespace, target file, sample)
VARIANTS = [
    (EXTRACT, TRANSFORM, "Quote_Id__c", "rlm-hvac-proposal", "Brightline_Proposal(Version 1)", SAMPLE_OUTPUT),
    ("RLMHVACReplacementProposalExtract", "RLMHVACReplacementProposalTransform", "Replacement_Quote_Id__c",
     "rlm-hvac-replacement-proposal", "Brightline_Replacement_Proposal(Version 1)", REPLACEMENT_SAMPLE),
]

NAMESPACE = "rlm-hvac-proposal"


def key(name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"{NAMESPACE}/{name}"))


def item(name, fields):
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


def doc(name, dtype, items, preview, expected=None, target=None):
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


def build_extract(extract, finding_field):
    items = []
    for seq, obj, field, op, value, out in QUERIES:
        if obj == "RLM_HVAC_Finding__c":
            field = finding_field
        f = common(extract, key(f"q/{seq}/{field}/{op}"))
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
        items.append(item(extract, f))
    for src, out, fmt in MAPPINGS:
        f = common(extract, key(f"m/{out}"))
        f.update({
            "inputFieldName": src,
            "inputObjectQuerySequence": "0.0",
            "outputCreationSequence": "1.0",
            "outputFieldFormat": fmt,
            "outputFieldName": out,
            "outputObjectName": "json",
            "transformValuesMappings": "{ }",
        })
        if out in DEFAULTS:
            f["defaultValue"] = DEFAULTS[out]
        items.append(item(extract, f))
    return doc(extract, "Extract", items, {"Id": "0Q0Ka000000EXAMPLE"})


def build_transform(transform, target, sample):
    items = []
    for _, out, _ in MAPPINGS:
        f = common(transform, key(f"t/{out}"))
        f.update({
            "inputFieldName": out,
            "inputObjectQuerySequence": "0.0",
            "outputCreationSequence": "1.0",
            "outputFieldName": out,
            "outputObjectName": "json",
            "transformValuesMappings": "{ }",
        })
        items.append(item(transform, f))
    return doc(transform, "Transform", items, sample, expected=sample, target=target)


os.makedirs(OUT, exist_ok=True)
for extract, transform, finding_field, NAMESPACE, target, sample in VARIANTS:
    for name, body in [(extract, build_extract(extract, finding_field)), (transform, build_transform(transform, target, sample))]:
        with open(os.path.join(OUT, f"{name}_1.rpt-meta.xml"), "w", encoding="utf-8") as fh:
            fh.write(body)
print("wrote", OUT)
