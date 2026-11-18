"""
Verdant Field Assistant MCP server.

Runs the Verdant pest storyline from an LLM: a caller books a free inspection, the technician walks
the property and quotes, the customer signs, the order books the first treatment, and on the
treatment day the technician records the work and adds upgrades or add-ons. Every read and write goes
to Salesforce through the RLM_RTK_AssistantApi REST facade, which calls the same Apex the Field
Service screens use, so pricing, coverage, scheduling and billing rules stay in Salesforce.

Environment:
    VERDANT_ORG          sf CLI alias or username of the org (default: verdant)
    VERDANT_TRACE        JSONL execution trace path (default: ~/.verdant-field-assistant/trace.jsonl)
    VERDANT_ADMIN_TOOLS  1 to expose reset_demo (presenter only)
"""

import asyncio
import base64
import datetime
import io
import os
import re
from pathlib import Path
from typing import Annotated, Literal, Optional

from mcp.server.mcpserver import MCPServer
from pydantic import Field

from verdant_assistant.salesforce import Refused, from_environment, today_central

PROMPT_FILE = Path(__file__).resolve().parent.parent / "verdant_assistant_prompt.md"
ACCOUNT_ID = re.compile(r"^001[0-9A-Za-z]{12}([0-9A-Za-z]{3})?$")
PHOTO_MAX_PX = 1600

mcp = MCPServer(
    "verdant-field-assistant",
    instructions=(
        "Verdant pest control field assistant. Salesforce is the system of record: read before you "
        "answer, never invent prices, times or coverage, and ask the customer before any tool that "
        "commits them (signing, add-ons, plan changes). Times come back with a Central-time *Local label."
    ),
)
sf = from_environment()

Visit = Annotated[str, Field(description="The visit: a work order Id or service appointment Id from get_my_schedule.")]
Customer = Annotated[str, Field(description="Customer name as it appears in Salesforce (for example 'Sam Patel') or an Account Id.")]
Day = Annotated[Optional[str], Field(description="Day as YYYY-MM-DD, or 'today' / 'tomorrow'. Central time.")]
Hour = Annotated[Optional[int], Field(description="Start hour on the 24-hour clock, Central time (for example 10 or 14).")]
Zone = Literal["Exterior Perimeter", "Garage", "Kitchen", "Bathrooms", "Living Areas", "Basement / Crawlspace", "Attic", "Yard"]
Pest = Literal["Ants", "Spiders", "Cockroaches", "Rodents", "Termites", "Mosquitoes", "Wasps / Bees", "Bed Bugs", "Other"]
Evidence = Literal["Live Activity", "Droppings", "Damage", "Nest", "Entry Point", "Standing Water", "Wood-to-Soil Contact", "Moisture"]
Severity = Literal["Light", "Moderate", "Heavy"]
PlanSku = Literal["RTK-ESSENTIAL", "RTK-HOME-PROT", "RTK-HOME-PROT-PLUS"]
ApprovedBy = Annotated[str, Field(description="Name of the customer who said yes to this on site. Ask them first.")]


def _day(value: Optional[str]) -> Optional[str]:
    if value is None or not value.strip():
        return None
    text = value.strip().lower()
    if text == "today":
        return today_central().isoformat()
    if text == "tomorrow":
        return (today_central() + datetime.timedelta(days=1)).isoformat()
    try:
        return datetime.date.fromisoformat(text[:10]).isoformat()
    except ValueError:
        raise Refused(f"'{value}' isn't a day I can book. Use YYYY-MM-DD, today or tomorrow.")


async def _account(tool: str, customer: str) -> str:
    if ACCOUNT_ID.match(customer.strip()):
        return customer.strip()
    matches = await sf.call(tool, "findCustomers", {"search": customer})
    exact = [m for m in matches if m["name"].lower() == customer.strip().lower()]
    picks = exact or matches
    if len(picks) == 1:
        return picks[0]["accountId"]
    if not picks:
        raise Refused(f"No customer named {customer} in Salesforce.")
    raise Refused(f"Several customers match {customer}: {', '.join(m['name'] for m in picks)}. Which one?")


async def _poll(tool: str, operation: str, params: dict, done, seconds: int, interval: float = 4):
    deadline = asyncio.get_running_loop().time() + seconds
    while True:
        result = await sf.call(tool, operation, params)
        if done(result) or asyncio.get_running_loop().time() > deadline:
            return result
        await asyncio.sleep(interval)


# ---------- 1. The customer calls ----------

@mcp.tool()
async def book_inspection_for_caller(
    name: Annotated[str, Field(description="Caller's full name.")],
    street: Annotated[str, Field(description="Street address of the property, for example '218 Maple Ridge Dr'.")],
    description: Annotated[str, Field(description="What the caller is seeing, in their words, for the technician.")],
    day: Day = None,
    hour: Hour = None,
    phone: Optional[str] = None,
    email: Optional[str] = None,
    city: Annotated[Optional[str], Field(description="Defaults to Bloomingdale.")] = None,
    postal_code: Annotated[Optional[str], Field(description="Defaults to 60108.")] = None,
) -> dict:
    """Books a new caller's free Pest Inspection and dispatches it to the technician.

    Creates the customer and contact in Salesforce if they're new. Calling again for the same person
    moves the open inspection instead of booking a second one. Defaults to tomorrow at 10:00.
    Customers who already have a plan are refused; use report_reservice for them.
    """
    return await sf.call("book_inspection_for_caller", "bookInspection", {
        "name": name, "street": street, "description": description, "day": _day(day), "hour": hour,
        "phone": phone, "email": email, "city": city, "postalCode": postal_code,
    })


@mcp.tool()
async def report_reservice(
    customer: Customer,
    pest: Pest,
    description: Annotated[str, Field(description="What the customer reports, in their words.")],
    day: Day = None,
    hour: Hour = None,
) -> dict:
    """Books a Pest Re-service for an existing customer who reports pests between visits.

    Salesforce decides coverage from the customer's guarantees: a Covered re-service is free and gets
    a response deadline; a Not Covered one is billable. Tell the customer which it is.
    """
    return await sf.call("report_reservice", "bookReservice", {
        "accountId": await _account("report_reservice", customer), "pest": pest,
        "description": description, "day": _day(day), "hour": hour,
    })


@mcp.tool()
async def find_customer(search: Annotated[str, Field(description="Part of the customer's name.")]) -> dict:
    """Finds customers by name, with their address and whether they have a plan."""
    return {"customers": await sf.call("find_customer", "findCustomers", {"search": search})}


# ---------- 2. Plan the day ----------

@mcp.tool()
async def get_my_schedule(day: Day = None) -> dict:
    """The technician's visits for a day (default today), in order, with customer, address and visit Ids."""
    chosen = _day(day) or today_central().isoformat()
    visits = await sf.call("get_my_schedule", "schedule", {"day": chosen})
    return {"day": chosen, "today": today_central().isoformat(), "visits": visits}


@mcp.tool()
async def get_visit_brief(visit: Visit, regenerate: bool = False) -> dict:
    """A short pre-visit brief: who the customer is, their plans, history and what to look for."""
    return await sf.call("get_visit_brief", "visitBrief", {"recordId": visit, "regenerate": regenerate})


@mcp.tool()
async def get_customer_summary(customer: Customer) -> dict:
    """The customer's plans and monthly price, scheduled changes, guarantees, visits, invoices and balance."""
    return await sf.call("get_customer_summary", "customerSummary",
                         {"accountId": await _account("get_customer_summary", customer)})


@mcp.tool()
async def get_visit_status(visit: Visit) -> dict:
    """Where a visit stands: stage (start, walk, customer, order), inspection, quote, signature, order, timing."""
    return await sf.call("get_visit_status", "visitContext", {"recordId": visit})


# ---------- 3. Inspect ----------

@mcp.tool()
async def start_visit(visit: Visit) -> dict:
    """Starts the visit when the technician arrives. On an inspection visit this opens the inspection."""
    return await sf.call("start_visit", "startVisit", {"recordId": visit})


@mcp.tool()
async def record_finding(
    visit: Visit,
    zone: Zone,
    pest: Pest,
    evidence: Evidence,
    severity: Severity,
    customer_note: Annotated[str, Field(description="Plain-language note the customer sees on the proposal.")],
    internal_note: Annotated[Optional[str], Field(description="Technician-only note.")] = None,
    finding_id: Annotated[Optional[str], Field(description="Pass to update an existing finding instead of adding one.")] = None,
) -> dict:
    """Records one inspection finding. Returns all findings plus Salesforce's plan recommendation."""
    return await sf.call("record_finding", "recordFinding", {
        "recordId": visit, "zone": zone, "pest": pest, "evidence": evidence, "severity": severity,
        "customerNote": customer_note, "internalNote": internal_note, "findingId": finding_id,
    })


@mcp.tool()
async def attach_finding_photo(
    finding_id: str,
    image_path: Annotated[Optional[str], Field(description="Path to a photo on this computer.")] = None,
    image_base64: Annotated[Optional[str], Field(description="The photo as base64, when there's no file.")] = None,
    stage: Literal["Before", "After"] = "Before",
) -> dict:
    """Attaches a photo to a finding (Before during inspection, After once treated)."""
    if image_path:
        data, name = _photo(Path(image_path).expanduser())
    elif image_base64:
        data, name = image_base64.split(",")[-1], f"finding-{stage.lower()}.jpg"
    else:
        raise Refused("Give me a photo file path or the image data.")
    return await sf.call("attach_finding_photo", "attachPhoto",
                         {"findingId": finding_id, "fileName": name, "base64Data": data, "stage": stage})


def _photo(path: Path):
    from PIL import Image

    if not path.is_file():
        raise Refused(f"There's no photo at {path}.")
    with Image.open(path) as image:
        image = image.convert("RGB")
        image.thumbnail((PHOTO_MAX_PX, PHOTO_MAX_PX))
        buffer = io.BytesIO()
        image.save(buffer, "JPEG", quality=85)
    return base64.b64encode(buffer.getvalue()).decode(), path.stem + ".jpg"


@mcp.tool()
async def get_inspection(visit: Visit) -> dict:
    """The visit's findings (with treatment status), plan recommendation and plan explanation."""
    return await sf.call("get_inspection", "inspection", {"recordId": visit})


# ---------- 4. Quote ----------

@mcp.tool()
async def get_plan_pricing(postal_code: str = "60108") -> dict:
    """Plan prices for a service zone, with the home size and severity adjustments Salesforce applies."""
    return await sf.call("get_plan_pricing", "pricing", {"postalCode": postal_code})


@mcp.tool()
async def create_quote(
    visit: Visit,
    plan_sku: PlanSku,
    square_footage: Literal["Under2000", "2000to3500", "Over3500"],
    severity: Severity,
    include_mosquito: bool = False,
    include_termite: bool = False,
    property_type: Literal["SingleFamily", "Townhome"] = "SingleFamily",
    override_reason: Annotated[Optional[str], Field(
        description="Required when the plan differs from the inspection's recommendation; why.")] = None,
) -> dict:
    """Creates the priced Revenue Cloud quote from the inspection (plan, add-on plans, one-time Initial Service).

    Use the plan, severity and add-on plans from the inspection's recommendation unless the
    technician chooses otherwise. Salesforce prices it; read the totals back from the result.
    """
    return await sf.call("create_quote", "createQuote", {
        "recordId": visit, "planSku": plan_sku, "squareFootage": square_footage, "severity": severity,
        "includeMosquito": include_mosquito, "includeTermite": include_termite,
        "propertyType": property_type, "overrideReason": override_reason,
    })


@mcp.tool()
async def get_quote(quote_id: str) -> dict:
    """The quote's lines, monthly and one-time totals, plan explanation, signature and proposal."""
    return await sf.call("get_quote", "quote", {"quoteId": quote_id})


@mcp.tool()
async def generate_proposal(quote_id: str) -> dict:
    """Generates the Verdant proposal PDF for the quote and waits up to about 90 seconds for it."""
    started = await sf.call("generate_proposal", "startProposal", {"quoteId": quote_id})
    if started.get("status") != "Generating":
        return started
    return await _poll("generate_proposal", "proposalStatus",
                       {"processId": started.get("processId"), "quoteId": quote_id},
                       lambda r: r.get("status") != "Generating", 90)


@mcp.tool()
async def get_proposal_status(quote_id: str, process_id: str) -> dict:
    """Checks on a proposal that was still generating."""
    return await sf.call("get_proposal_status", "proposalStatus", {"processId": process_id, "quoteId": quote_id})


# ---------- 5. Sign and order ----------

@mcp.tool()
async def record_customer_acceptance(
    quote_id: str,
    signer_name: Annotated[str, Field(description="Full name of the customer signing.")],
    customer_statement: Annotated[str, Field(
        description="What the customer said to accept, in their words (for example 'Yes, let's do Home Protection').")],
    card_last4: Annotated[Optional[str], Field(description="Last four digits of the card on file, if given.")] = None,
    card_brand: Optional[str] = None,
) -> dict:
    """Records the customer's signature on the proposal. Only after they've seen the price and said yes."""
    return await sf.call("record_customer_acceptance", "acceptQuote", {
        "quoteId": quote_id, "signerName": signer_name, "approvalStatement": customer_statement,
        "cardLast4": card_last4, "cardBrand": card_brand,
    })


@mcp.tool()
async def place_order(quote_id: str) -> dict:
    """Turns the signed quote into an activated order. Fulfillment then creates the Initial Pest
    Treatment visit; this waits up to about 2 minutes for it so the follow-up can be booked."""
    await sf.call("place_order", "placeOrder", {"quoteId": quote_id})
    return await _poll("place_order", "orderStatus", {"quoteId": quote_id},
                       lambda r: bool(r.get("treatmentAppointmentId")), 120, interval=6)


@mcp.tool()
async def get_order_status(quote_id: str) -> dict:
    """The order's status and the Initial Pest Treatment visit fulfillment created for it."""
    return await sf.call("get_order_status", "orderStatus", {"quoteId": quote_id})


# ---------- 6. Schedule the follow-up ----------

@mcp.tool()
async def find_treatment_slots(appointment_id: Annotated[str, Field(
        description="The treatment's service appointment Id (treatmentAppointmentId from place_order).")]) -> dict:
    """Open times for the first treatment. Offer two or three to the customer."""
    return {"slots": await sf.call("find_treatment_slots", "treatmentSlots", {"appointmentId": appointment_id})}


@mcp.tool()
async def book_treatment(
    appointment_id: str,
    start_time: Annotated[str, Field(description="A slot's startTime value exactly as find_treatment_slots returned it.")],
) -> dict:
    """Books the first treatment at the slot the customer picked and dispatches it to the technician."""
    return await sf.call("book_treatment", "bookTreatment", {"appointmentId": appointment_id, "startTime": start_time})


# ---------- 7. The treatment visit ----------

@mcp.tool()
async def get_treatment_checklist(visit: Visit) -> dict:
    """The findings to treat on this visit, from the inspection, with their treatment status."""
    return await sf.call("get_treatment_checklist", "inspection", {"recordId": visit})


@mcp.tool()
async def record_treatment(
    visit: Visit,
    finding_id: str,
    status: Literal["Treated", "Needs Follow-up", "Open"],
    note: Annotated[str, Field(description="What was done, in plain language for the visit summary.")],
) -> dict:
    """Records the treatment of one finding."""
    return await sf.call("record_treatment", "recordTreatment",
                         {"recordId": visit, "findingId": finding_id, "status": status, "note": note})


@mcp.tool()
async def get_add_on_options(visit: Visit) -> dict:
    """One-time add-on services (wasp nest removal, rodent exclusion, attic sanitation, bed bug treatment)
    with prices, which ones the findings recommend, and what's already added to this visit."""
    return await sf.call("get_add_on_options", "addOnOptions", {"recordId": visit})


@mcp.tool()
async def add_add_ons(
    visit: Visit,
    skus: Annotated[list[str], Field(description="Add-on SKUs from get_add_on_options, for example ['RTK-WASP-NEST'].")],
    approved_by: ApprovedBy,
) -> dict:
    """Adds one-time add-ons the customer approved; they're billed on the next invoice."""
    return await sf.call("add_add_ons", "addAddOns", {"recordId": visit, "skus": skus, "approvedBy": approved_by})


@mcp.tool()
async def get_plan_options(visit: Visit) -> dict:
    """The customer's current plan and monthly total, and every tier or add-on plan they could move to with
    its new monthly price."""
    return await sf.call("get_plan_options", "planOptions", {"recordId": visit})


@mcp.tool()
async def change_plan(
    visit: Visit,
    sku: Annotated[str, Field(description="The tier or add-on plan SKU from get_plan_options.")],
    approved_by: ApprovedBy,
) -> dict:
    """Upgrades, downgrades, adds or removes a plan through a Revenue Cloud amendment, from tomorrow.
    Assets, guarantees, visits and prorated billing follow automatically."""
    return await sf.call("change_plan", "changePlan", {"recordId": visit, "sku": sku, "approvedBy": approved_by})


@mcp.tool()
async def complete_visit(visit: Visit) -> dict:
    """Completes the visit. Completing the first treatment starts the guarantees and the maintenance
    visit schedule from the customer's plans."""
    return await sf.call("complete_visit", "completeVisit", {"recordId": visit})


@mcp.tool()
async def send_visit_summary(visit: Visit) -> dict:
    """Writes the customer's visit summary and emails it to them. Only after complete_visit.
    If emailError says the record was locked, Salesforce is still processing the visit: try again in a minute."""
    return await sf.call("send_visit_summary", "visitSummary", {"recordId": visit})


# ---------- 8. Billing ----------

@mcp.tool()
async def explain_bill(
    customer: Customer,
    amount: Annotated[Optional[float], Field(description="The bill amount they're asking about, if they said one.")] = None,
    invoice_number: Optional[str] = None,
) -> dict:
    """Explains a customer's invoice line by line (plans, proration, add-ons, tax). Invoices are generated
    automatically from the plans; this only reads them."""
    return await sf.call("explain_bill", "explainBill", {
        "accountId": await _account("explain_bill", customer), "amount": amount, "invoiceNumber": invoice_number,
    })


# ---------- Presenter ----------

if os.environ.get("VERDANT_ADMIN_TOOLS") == "1":
    @mcp.tool()
    async def reset_demo(customer_name: str = "Sarah Mitchell") -> dict:
        """Presenter only: archives the customer the assistant created for this name and cancels their open
        visits, so the demo can start over. Never call this during the customer conversation."""
        return await sf.call("reset_demo", "resetDemo", {"customerName": customer_name})


@mcp.prompt(name="verdant_field_assistant", description="Act as the Verdant Field Assistant for the pest demo.")
def verdant_field_assistant() -> str:
    return PROMPT_FILE.read_text()


def main():
    mcp.run()


if __name__ == "__main__":
    main()
