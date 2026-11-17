"""
Plays the whole Verdant storyline through the MCP tools, the calls an LLM would make, as the scripted
caller Sarah Mitchell. Use it to check an org before a live demo; it stops at the first refusal.

    uv run python rehearse.py            # leaves Sarah in place, as after a live run
    uv run python rehearse.py --reset    # archives the last Sarah first, then runs
    uv run python rehearse.py --resume   # picks up at the follow-up from Sarah's existing order

Writes real records: a customer, inspection, quote, proposal, order, treatment, add-on and plan change.
"""

import asyncio
import json
import os
import subprocess
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

CALLER = "Sarah Mitchell"
FINDINGS = [
    {"zone": "Kitchen", "pest": "Ants", "evidence": "Live Activity", "severity": "Moderate",
     "customer_note": "Ant trail along the sink and under the dishwasher."},
    {"zone": "Exterior Perimeter", "pest": "Wasps / Bees", "evidence": "Nest", "severity": "Moderate",
     "customer_note": "Paper wasp nest under the back porch eaves."},
    {"zone": "Attic", "pest": "Rodents", "evidence": "Droppings", "severity": "Moderate",
     "customer_note": "Fresh mouse droppings next to the attic hatch."},
]


class Stop(Exception):
    pass


class Rehearsal:
    def __init__(self, session):
        self.session = session

    async def call(self, tool, **arguments):
        result = await self.session.call_tool(tool, arguments)
        texts = [getattr(b, "text", "") for b in result.content]
        if result.is_error:
            raise Stop(f"{tool} refused: {''.join(texts)}")
        print(f"✓ {tool}")
        return json.loads("".join(texts))


def say(line):
    print(f"  {line}")


async def rehearse(session, resume):
    r = Rehearsal(session)
    if resume:
        quote_id = (await r.call("get_customer_summary", customer=CALLER))["latestQuoteId"]
        order = await r.call("get_order_status", quote_id=quote_id)
    else:
        order = await first_visit(r)
    await follow_up(r, order)


async def first_visit(r):
    print("\n1. Sarah calls")
    booking = await r.call("book_inspection_for_caller", name=CALLER, street="218 Maple Ridge Dr",
                           phone="(630) 555-0101", day="tomorrow", hour=9,
                           description="Ants in the kitchen, something buzzing by the back porch, noises in the attic.")
    say(f"Inspection {booking['workOrderNumber']} at {booking['startTimeLocal']}")

    print("\n2. Plan the day")
    schedule = await r.call("get_my_schedule", day="tomorrow")
    visit = next(v for v in schedule["visits"] if v["accountName"] == CALLER)["appointmentId"]
    brief = await r.call("get_visit_brief", visit=visit)
    say(brief.get("headline") or "")

    print("\n3. Inspect")
    await r.call("start_visit", visit=visit)
    for finding in FINDINGS:
        state = await r.call("record_finding", visit=visit, **finding)
    recommendation = state["recommendation"]
    say(f"Recommended {recommendation['planSku']} ({recommendation['severity']}): {recommendation.get('summary')}")

    print("\n4. Quote")
    created = await r.call("create_quote", visit=visit, plan_sku=recommendation["planSku"], square_footage="Under2000",
                           severity=recommendation["severity"], include_mosquito=recommendation["includeMosquito"],
                           include_termite=recommendation["includeTermite"])
    quote = created["quote"]
    say(f"Quote {quote['quoteNumber']}: ${quote['monthlyTotal']}/mo, ${quote['oneTimeTotal']} one time")
    proposal = await r.call("generate_proposal", quote_id=quote["quoteId"])
    say(f"Proposal {proposal['status']}: {proposal.get('title') or proposal.get('message')}")

    print("\n5. Sign and order")
    await r.call("record_customer_acceptance", quote_id=quote["quoteId"], signer_name=CALLER,
                 customer_statement="Yes, that works. Let's do it.", card_last4="4242", card_brand="Visa")
    order = await r.call("place_order", quote_id=quote["quoteId"])
    say(f"Order {order.get('orderNumber')} {order.get('status')}, treatment {order.get('treatmentWorkOrderNumber')}")
    if not order.get("treatmentAppointmentId"):
        raise Stop("Fulfillment hasn't created the treatment yet; run again with --resume in a minute.")
    order["inspectionVisit"] = visit
    return order


async def follow_up(r, order):
    print("\n6. Schedule the follow-up")
    slots = (await r.call("find_treatment_slots", appointment_id=order["treatmentAppointmentId"]))["slots"]
    booked = await r.call("book_treatment", appointment_id=order["treatmentAppointmentId"], start_time=slots[0]["startTime"])
    say(f"Treatment at {booked.get('treatmentScheduledStartLocal') or slots[0]['startTimeLocal']}")
    if order.get("inspectionVisit"):
        await r.call("complete_visit", visit=order["inspectionVisit"])

    print("\n7. Treatment day")
    treatment = order["treatmentAppointmentId"]
    await r.call("start_visit", visit=treatment)
    checklist = await r.call("get_treatment_checklist", visit=treatment)
    for finding in checklist["findings"]:
        await r.call("record_treatment", visit=treatment, finding_id=finding["id"], status="Treated",
                     note=f"Treated {finding['pest'].lower()} in the {finding['zone'].lower()}.")
    options = await r.call("get_add_on_options", visit=treatment)
    recommended = [a["sku"] for a in options["addOns"] if a.get("recommended") and not a.get("added")]
    if recommended:
        added = await r.call("add_add_ons", visit=treatment, skus=recommended[:1], approved_by=CALLER)
        say(f"Add-ons on this visit: ${added['total']}")
    plans = await r.call("get_plan_options", visit=treatment)
    say(f"Current plan {plans.get('currentPlanName')} at ${plans.get('monthlyTotal')}/mo")
    upgrade = next((t for t in plans.get("tiers", []) if t.get("sku") == "RTK-HOME-PROT-PLUS"), None)
    if upgrade and not plans.get("lockedReason"):
        changed = await r.call("change_plan", visit=treatment, sku=upgrade["sku"], approved_by=CALLER)
        say(f"Scheduled: {[s.get('summary') for s in changed.get('scheduled', [])]}")
    await r.call("complete_visit", visit=treatment)
    summary = await r.call("send_visit_summary", visit=treatment)
    say(f"Summary emailed to {summary.get('emailedTo')}")

    print("\n8. After the visit")
    customer = await r.call("get_customer_summary", customer=CALLER)
    say(f"Plans: {[(p['name'], p['monthlyPrice']) for p in customer['plans']]}")
    say(f"Guarantees: {customer['guarantees']}")
    say(f"Upcoming: {customer['openVisits'][:3]}")


async def main():
    if "--reset" in sys.argv:
        print("Resetting")
        subprocess.run(["cci", "task", "run", "reset_verdant_llm_demo", "--org", os.environ.get("VERDANT_ORG", "verdant"),
                        "-o", "reseed", "false"], check=True, cwd=os.path.join(os.path.dirname(__file__), "..", ".."))
    server = StdioServerParameters(command=sys.executable, args=["-m", "verdant_assistant.server"], env=dict(os.environ))
    async with stdio_client(server) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            try:
                await rehearse(session, "--resume" in sys.argv)
            except Stop as stop:
                print(f"\n✗ {stop}")
                return 1
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
