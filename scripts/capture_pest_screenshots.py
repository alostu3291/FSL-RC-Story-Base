#!/usr/bin/env python3
"""Capture Rentokil pest story screenshots from fsl-rc into screenshots/pest/.

Uses Playwright + sf org open URL. Visits existing Michael Reyes records.

Usage:
    /tmp/pest-shots/bin/python scripts/capture_pest_screenshots.py
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(os.environ.get("OUT_DIR", ROOT / "screenshots" / "pest"))
ORG = os.environ.get("FSL_ORG", "fsl-rc")
OUT.mkdir(parents=True, exist_ok=True)


def sf_json(*args):
    r = subprocess.run(["sf", *args, "--target-org", ORG, "--json"], capture_output=True, text=True)
    return json.loads(r.stdout or "{}")


def q(soql):
    return sf_json("data", "query", "-q", soql).get("result", {}).get("records", [])


def q1(soql):
    rows = q(soql)
    return rows[0] if rows else None


def main():
    acct = q1("SELECT Id FROM Account WHERE Name = 'Michael Reyes' LIMIT 1")
    quote = q1(
        "SELECT Id, QuoteNumber FROM Quote WHERE Account.Name = 'Michael Reyes' "
        "ORDER BY CreatedDate DESC LIMIT 1"
    )
    order = q1(
        "SELECT Id, OrderNumber FROM Order WHERE Account.Name = 'Michael Reyes' "
        "ORDER BY CreatedDate DESC LIMIT 1"
    )
    opp = q1(
        "SELECT Id FROM Opportunity WHERE Account.Name = 'Michael Reyes' "
        "AND StageName = 'Closed Won' ORDER BY CreatedDate DESC LIMIT 1"
    )
    exp_opp = q1(
        "SELECT Id FROM Opportunity WHERE Account.Name = 'Michael Reyes' "
        "AND StageName = 'Qualification' ORDER BY CreatedDate DESC LIMIT 1"
    )
    wo = q1(
        "SELECT Id FROM WorkOrder WHERE Account.Name = 'Michael Reyes' "
        "ORDER BY CreatedDate DESC LIMIT 1"
    )
    asset = q1(
        "SELECT Id FROM Asset WHERE Account.Name = 'Michael Reyes' "
        "AND Product2.StockKeepingUnit = 'RTK-HOME-PROT' LIMIT 1"
    )
    mp = q1("SELECT Id FROM MaintenancePlan WHERE Account.Name = 'Michael Reyes' LIMIT 1")
    fp = None
    if order:
        fp = q1(f"SELECT Id FROM FulfillmentPlan WHERE SourceIdentifier = '{order['Id']}' LIMIT 1")
    territory = q1("SELECT Id FROM ServiceTerritory WHERE Name = 'Bloomingdale IL' LIMIT 1")

    records = {
        "accountId": acct and acct["Id"],
        "quoteId": quote and quote["Id"],
        "quoteNumber": quote and quote.get("QuoteNumber"),
        "orderId": order and order["Id"],
        "orderNumber": order and order.get("OrderNumber"),
        "opportunityId": opp and opp["Id"],
        "expansionOpportunityId": exp_opp and exp_opp["Id"],
        "workOrderId": wo and wo["Id"],
        "assetId": asset and asset["Id"],
        "maintenancePlanId": mp and mp["Id"],
        "fulfillmentPlanId": fp and fp["Id"],
        "territoryId": territory and territory["Id"],
    }
    (OUT / "story-records.json").write_text(json.dumps(records, indent=2) + "\n")
    print(json.dumps(records, indent=2))

    info = sf_json("org", "open", "--url-only")
    login_url = info["result"]["url"]
    base = login_url.split("/secur/")[0].replace(".my.salesforce.com", ".lightning.force.com")

    pages = []
    if acct:
        pages.append(("s1-01-account", f"{base}/lightning/r/Account/{acct['Id']}/view"))
    if territory:
        pages.append(("s1-02-territory", f"{base}/lightning/r/ServiceTerritory/{territory['Id']}/view"))
    if quote:
        pages.append(("s2-01-quote", f"{base}/lightning/r/Quote/{quote['Id']}/view"))
    if opp:
        pages.append(("s2-02-opportunity", f"{base}/lightning/r/Opportunity/{opp['Id']}/view"))
    if order:
        pages.append(("s3-01-order", f"{base}/lightning/r/Order/{order['Id']}/view"))
    if fp:
        pages.append(("s4-01-fulfillment-plan", f"{base}/lightning/r/FulfillmentPlan/{fp['Id']}/view"))
    if order:
        pages.append(("s4-02-order", f"{base}/lightning/r/Order/{order['Id']}/view"))
    if wo:
        pages.append(("s5-01-work-order", f"{base}/lightning/r/WorkOrder/{wo['Id']}/view"))
    if mp:
        pages.append(("s6-01-maintenance-plan", f"{base}/lightning/r/MaintenancePlan/{mp['Id']}/view"))
    if asset:
        pages.append(("s6-02-asset", f"{base}/lightning/r/Asset/{asset['Id']}/view"))
        pages.append(("s7-01-asset", f"{base}/lightning/r/Asset/{asset['Id']}/view"))
    if wo:
        pages.append(("s7-02-work-order", f"{base}/lightning/r/WorkOrder/{wo['Id']}/view"))
    if exp_opp:
        pages.append(("s8-01-expansion-opportunity", f"{base}/lightning/r/Opportunity/{exp_opp['Id']}/view"))
    if wo:
        pages.append(("s8-02-work-order", f"{base}/lightning/r/WorkOrder/{wo['Id']}/view"))
    if asset:
        pages.append(("s9-01-asset", f"{base}/lightning/r/Asset/{asset['Id']}/view"))
    if acct:
        pages.append(("s9-02-account", f"{base}/lightning/r/Account/{acct['Id']}/view"))

    map_src = ROOT / "deck" / "preview-demo-map.png"
    if map_src.exists():
        (OUT / "s1-00-map.png").write_bytes(map_src.read_bytes())
        print("copied s1-00-map.png")

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context(viewport={"width": 1600, "height": 1100})
        page = context.new_page()
        page.goto(login_url, wait_until="domcontentloaded", timeout=120000)
        page.wait_for_timeout(8000)

        for name, url in pages:
            try:
                page.goto(url, wait_until="domcontentloaded", timeout=120000)
                page.wait_for_timeout(10000)
                # dismiss any leftover spinners if possible
                path = OUT / f"{name}.png"
                page.screenshot(path=str(path), full_page=False)
                print("saved", name, path.stat().st_size)
            except Exception as e:
                print("FAILED", name, e)

        browser.close()

    print("done", len(list(OUT.glob("*.png"))), "pngs in", OUT)


if __name__ == "__main__":
    main()
