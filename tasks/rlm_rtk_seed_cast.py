"""
Seed the Verdant pest demo cast: one customer per scene, each left in the state its scene needs.

| Customer      | Scenes | State                                                                   |
|---------------|--------|-------------------------------------------------------------------------|
| Nora Castillo | 1-3    | Prospect; free inspection tomorrow 8:00                                 |
| Aisha Brooks  | 1, 4-5 | Signed and ordered today; first treatment tomorrow 11:00                |
| Casey Morgan  | 1, 7-8 | Home Protection at $79/mo for 2 weeks; Covered rodent re-service 15:00  |
| Sam Patel     | 1, 6-9 | Three plans for 3 weeks ($366 first bill); mosquito paused for winter;  |
|               |        | Not Covered bed bug re-service 16:00                                    |
| Dana Whitfield| 8      | Home Protection for a month, upgraded to Plus today; prorated bill      |

Customers go through the same Apex the field flows use: inspection findings, a priced quote (dated
back for existing customers), Sign & Pay, order activation, the fulfillment-created first treatment,
coverage, and dated plan changes. Each stage runs as its own anonymous Apex call, because order
creation, fulfillment, assetization, coverage and invoicing all finish asynchronously.

Re-running skips the stages a customer has already been through and moves tomorrow's visits to the
new day. A customer whose scene was run live (Aisha treated, Nora quoted) is used up: archive the
account ("zz Archived - ...") and run again to recreate it.

Usage:
    cci task run seed_rtk_demo_cast --org fsl-rc
    cci task run seed_rtk_demo_cast --org fsl-rc -o customers "Aisha Brooks,Sam Patel"
"""

import calendar
import datetime
import json
import os
import time
from zoneinfo import ZoneInfo

try:
    from cumulusci.core.exceptions import CommandException, TaskOptionsError
    from cumulusci.tasks.salesforce import BaseSalesforceApiTask
except ImportError:
    BaseSalesforceApiTask = object
    CommandException = Exception
    TaskOptionsError = Exception

from tasks.rlm_rtk_seed_visit import _apex_string

APEX_DIR = os.path.join("scripts", "apex")
# The Bloomingdale IL territory's clock; visit hours are on it.
CENTRAL = ZoneInfo("America/Chicago")


def _months_ago(day, months):
    year, month = divmod(day.month - 1 - months, 12)
    year, month = day.year + year, month + 1
    return day.replace(year=year, month=month, day=min(day.day, calendar.monthrange(year, month)[1]))


def _winter_pause(today):
    """First of next month, and the following April 1."""
    pause = (today.replace(day=1) + datetime.timedelta(days=32)).replace(day=1)
    resume = datetime.date(pause.year if pause.month < 4 else pause.year + 1, 4, 1)
    return pause, resume


def _finding(zone, pest, evidence, severity, customer_note, internal_note=""):
    return {
        "zone": zone, "pest": pest, "evidence": evidence, "severity": severity,
        "customerNote": customer_note, "internalNote": internal_note,
    }


def build_cast(today):
    """The cast, with dates relative to today."""
    pause, resume = _winter_pause(today)
    return [
        {
            "name": "Nora Castillo", "scenes": "1-3", "role": "prospect",
            "street": "512 Sycamore Ln", "phone": "(630) 555-0142", "hour": 8,
            "description": "Called about ants in the kitchen, droppings in the attic and mud tubes on "
                           "the garage wall. Inspect and quote on site.",
        },
        {
            "name": "Aisha Brooks", "scenes": "4-5", "role": "customer",
            "street": "27 Maple Ct", "phone": "(630) 555-0177",
            "plan": "RTK-HOME-PROT", "sqft": "Under2000", "severity": "Moderate",
            "mosquito": False, "termite": False, "start_days_ago": 0,
            "treatment": "book", "hour": 11,
            "findings": [
                _finding("Kitchen", "Ants", "Live Activity", "Moderate",
                         "Ant trails along the kitchen baseboard and under the sink.",
                         "Odorous house ants; likely nesting by the sink plumbing."),
                _finding("Exterior Perimeter", "Wasps / Bees", "Nest", "Moderate",
                         "Paper wasp nest under the back porch eaves."),
                _finding("Attic", "Rodents", "Droppings", "Moderate",
                         "Fresh mouse droppings by the attic hatch.",
                         "Check the soffit vents for the entry point."),
            ],
        },
        {
            "name": "Casey Morgan", "scenes": "7-8", "role": "customer",
            "street": "203 Birchwood Dr", "phone": "(630) 555-0119",
            "plan": "RTK-HOME-PROT", "sqft": "2000to3500", "severity": "Moderate",
            "mosquito": False, "termite": False, "start_days_ago": 14,
            "treatment": "complete",
            "findings": [
                _finding("Attic", "Rodents", "Droppings", "Moderate",
                         "Mouse droppings along the attic insulation."),
                _finding("Kitchen", "Cockroaches", "Live Activity", "Light",
                         "A few German cockroaches behind the refrigerator."),
            ],
            "reservice": {
                "pest": "Rodents", "hour": 15, "require_coverage": "true",
                "description": "Customer hears scratching in the attic again and found fresh droppings by the furnace.",
            },
        },
        {
            "name": "Sam Patel", "scenes": "6-9", "role": "customer",
            "street": "415 Glenwood Ave", "phone": "(630) 555-0163",
            "plan": "RTK-HOME-PROT", "sqft": "Under2000", "severity": "Light",
            "mosquito": True, "termite": True, "start_days_ago": 21,
            "treatment": "complete",
            "findings": [
                _finding("Garage", "Termites", "Damage", "Light",
                         "Mud tubes on the garage wall by the side door."),
                _finding("Yard", "Mosquitoes", "Standing Water", "Light",
                         "Standing water in the birdbath and a clogged downspout."),
                _finding("Basement / Crawlspace", "Rodents", "Entry Point", "Light",
                         "Gap around the dryer vent where mice can get in."),
            ],
            "changes": [
                {"action": "change", "sku": "RTK-MOSQUITO", "start": pause, "order": "Plan change: Remove%Mosquito%"},
                {"action": "resume", "sku": "RTK-MOSQUITO", "start": resume, "order": "Plan change: Resume%"},
            ],
            "reservice": {
                "pest": "Bed Bugs", "hour": 16, "require_coverage": "false",
                "description": "Customer found bites and small blood spots on the guest bed sheets after a visit from family.",
            },
        },
        {
            "name": "Dana Whitfield", "scenes": "8", "role": "customer",
            "street": "61 Foxhall Ln", "phone": "(630) 555-0188",
            "plan": "RTK-HOME-PROT", "sqft": "Under2000", "severity": "Light",
            "mosquito": False, "termite": False, "start_days_ago": (today - _months_ago(today, 1)).days,
            "treatment": "complete",
            "findings": [
                _finding("Basement / Crawlspace", "Spiders", "Live Activity", "Light",
                         "Cobwebs and a few house spiders in the basement corners."),
                _finding("Garage", "Rodents", "Entry Point", "Light",
                         "Worn seal under the garage door."),
            ],
            "changes": [
                {"action": "change", "sku": "RTK-HOME-PROT-PLUS", "start": today, "order": "Plan change: Upgrade%"},
            ],
        },
    ]


class SeedRtkDemoCast(BaseSalesforceApiTask):
    """Seeds the pest demo cast in stages and reports what each customer is ready to show."""

    task_options = {
        "customers": {"description": "Comma-separated cast names to seed. Defaults to all.", "required": False},
        "days_ahead": {"description": "Day of the demo, in days from today. Defaults to 1 (tomorrow).", "required": False},
        "timeout": {"description": "Seconds to wait for each asynchronous step. Defaults to 300.", "required": False},
        "briefs": {"description": "Pre-generate the Einstein visit briefs for the demo day. Defaults to true.", "required": False},
    }

    def _init_options(self, kwargs):
        super()._init_options(kwargs)
        for name, default in (("days_ahead", "1"), ("timeout", "300")):
            value = str(self.options.get(name) or default)
            if not value.isdigit():
                raise TaskOptionsError(f"{name} must be a whole number, got {value!r}")
            self.options[name] = int(value)
        self.options["briefs"] = str(self.options.get("briefs", "true")).lower() != "false"

    def _run_task(self):
        cast = build_cast(datetime.date.today())
        wanted = self.options.get("customers")
        if wanted:
            names = {n.strip() for n in wanted.split(",") if n.strip()}
            unknown = names - {c["name"] for c in cast}
            if unknown:
                raise TaskOptionsError(f"Not in the cast: {', '.join(sorted(unknown))}")
            cast = [c for c in cast if c["name"] in names]
        customers = [c for c in cast if c["role"] == "customer"]

        for c in customers:
            self._sign_up(c)
        for c in customers:
            self._book_order(c)
        for c in customers:
            self._first_treatment(c)
        for c in customers:
            if c["treatment"] == "complete":
                self._wait_for_coverage(c)
        for c in customers:
            self._plan_changes(c)
        for c in cast:
            self._demo_day_visit(c)
        if self.options["briefs"]:
            self._briefs()
        for c in cast:
            self._report(c)

    # ---------- stages ----------

    def _sign_up(self, c):
        if self._count(f"SELECT COUNT() FROM RLM_RTK_Inspection__c WHERE Account__r.Name = '{self._q(c['name'])}' AND Quote__c != null"):
            return
        self.logger.info(f"{c['name']}: inspection findings, quote and signature")
        self._apex("seedRtkCastQuote.apex", {
            "ACCOUNT_NAME": c["name"], "STREET": c["street"], "PHONE": c["phone"],
            "START_DAYS_AGO": c["start_days_ago"], "FINDINGS": json.dumps(c["findings"]),
            "PLAN": c["plan"], "SQFT": c["sqft"], "SEVERITY": c["severity"],
            "MOSQUITO": str(c["mosquito"]).lower(), "TERMITE": str(c["termite"]).lower(),
        })

    def _book_order(self, c):
        status = self._order_status(c)
        if status == "Activated":
            return
        self.logger.info(f"{c['name']}: order")
        self._apex("seedRtkCastOrder.apex", {"ACCOUNT_NAME": c["name"]})
        if self._wait(lambda: self._order_status(c) in ("Draft", "Activated"), f"{c['name']}'s order") != "Activated":
            self._apex("seedRtkCastOrder.apex", {"ACCOUNT_NAME": c["name"]})
        self._wait(lambda: self._order_status(c) == "Activated", f"{c['name']}'s order activation")

    def _first_treatment(self, c):
        treatment = self._wait(lambda: self._treatment(c), f"{c['name']}'s first treatment from fulfillment")
        if treatment["Status"] == "Completed":
            if c["treatment"] == "book":
                self.logger.warning(f"{c['name']}'s first treatment was already completed; archive the account to recreate it.")
            return
        if c["treatment"] == "complete":
            self.logger.info(f"{c['name']}: first treatment completed")
        else:
            self.logger.info(f"{c['name']}: first treatment booked")
        self._apex("seedRtkCastTreatment.apex", {
            "ACCOUNT_NAME": c["name"], "MODE": c["treatment"], "HOUR": c.get("hour", 10),
            "DAYS_AHEAD": self.options["days_ahead"], "START_DAYS_AGO": c["start_days_ago"],
        })

    def _wait_for_coverage(self, c):
        name = self._q(c["name"])
        self._wait(
            lambda: self._count(f"SELECT COUNT() FROM Entitlement WHERE Account.Name = '{name}' AND RLM_RTK_Covered_Pests__c != null")
            and self._count(f"SELECT COUNT() FROM MaintenancePlan WHERE Account.Name = '{name}'"),
            f"{c['name']}'s guarantees and maintenance plan",
        )

    def _plan_changes(self, c):
        name = self._q(c["name"])
        for change in c.get("changes", []):
            if not self._count(f"SELECT COUNT() FROM Order WHERE Account.Name = '{name}' AND Name LIKE '{change['order']}'"):
                self.logger.info(f"{c['name']}: {change['action']} {change['sku']} from {change['start']}")
                self._apex("seedRtkCastPlanChange.apex", {
                    "ACCOUNT_NAME": c["name"], "ACTION": change["action"], "SKU": change["sku"],
                    "START_DATE": change["start"].isoformat(),
                })
            # The next change reads the asset's state periods, which assetization writes after activation.
            start = change["start"].isoformat()
            self._wait(
                lambda: self._count(
                    f"SELECT COUNT() FROM AssetStatePeriod WHERE Asset.Account.Name = '{name}' "
                    f"AND StartDate >= {start}T00:00:00Z AND StartDate <= {start}T23:59:59Z"),
                f"{c['name']}'s {change['action']} to be assetized",
            )

    def _demo_day_visit(self, c):
        days = self.options["days_ahead"]
        if c["role"] == "prospect":
            if self._count(f"SELECT COUNT() FROM Asset WHERE Account.Name = '{self._q(c['name'])}'"):
                self.logger.warning(f"{c['name']} already has plans; archive the account to recreate the prospect.")
                return
            self._apex("seedRtkProspectInspection.apex", {
                "ACCOUNT_NAME": c["name"], "STREET": c["street"], "PHONE": c["phone"], "SUBJECT": "",
                "DESCRIPTION": c["description"], "HOUR": c["hour"], "DAYS_AHEAD": days,
            })
        elif c.get("reservice"):
            r = c["reservice"]
            self._apex("seedRtkReservice.apex", {
                "ACCOUNT_NAME": c["name"], "PEST": r["pest"], "REQUIRE_COVERAGE": r["require_coverage"],
                "SUBJECT": "", "DESCRIPTION": r["description"], "HOUR": r["hour"], "DAYS_AHEAD": days,
            })

    def _briefs(self):
        for wo in self._demo_day_work_orders():
            try:
                self._run_apex(f"RLM_RTK_AI.getBrief('{wo['Id']}', false);")
            except CommandException as e:
                self.logger.warning(f"Visit brief for work order {wo['WorkOrderNumber']} not generated: {e}")

    # ---------- report ----------

    def _report(self, c):
        name = self._q(c["name"])
        self.logger.info("")
        self.logger.info(f"{c['name']} (scenes {c['scenes']})")
        for period in self._latest_periods(name):
            qty = period["Quantity"] or 0
            price = (period["Mrr"] or 0) / qty if qty else 0
            label = f"${price:,.2f}/mo" if qty else "off"
            self.logger.info(f"  Plan {period['Asset']['Product2']['Name']}: {label} from {period['StartDate'][:10]}")
        for e in self._query(
            f"SELECT Name, StartDate, EndDate FROM Entitlement WHERE Account.Name = '{name}' "
            "AND RLM_RTK_Covered_Pests__c != null ORDER BY StartDate"
        ):
            self.logger.info(f"  Guarantee {e['Name']}: {e['StartDate']} to {e['EndDate'] or 'ongoing'}")
        for o in self._query(
            f"SELECT OrderNumber, Name, EffectiveDate FROM Order WHERE Account.Name = '{name}' AND Name LIKE 'Plan change:%' ORDER BY EffectiveDate"
        ):
            self.logger.info(f"  {o['Name']} (order {o['OrderNumber']}, from {o['EffectiveDate']})")
        for inv in self._query(
            f"SELECT DocumentNumber, Status, InvoiceDate, TotalAmountWithTax, Balance FROM Invoice WHERE BillingAccount.Name = '{name}' ORDER BY DocumentNumber"
        ):
            self.logger.info(
                f"  Invoice {inv['DocumentNumber']} {inv['Status']} {inv['InvoiceDate']}: "
                f"${inv['TotalAmountWithTax'] or 0:,.2f} (balance ${inv['Balance'] or 0:,.2f})"
            )
        for wo in self._demo_day_work_orders(name):
            for sa in (wo.get("ServiceAppointments") or {}).get("records", []):
                self.logger.info(
                    f"  Demo day: {wo['WorkType']['Name']} work order {wo['WorkOrderNumber']}, "
                    f"appointment {sa['AppointmentNumber']} {sa['Status']} at {self._central(sa['SchedStartTime'])}"
                    + (f", {wo['RLM_Service_Coverage__c']}" if wo.get("RLM_Service_Coverage__c") else "")
                )

    # ---------- queries ----------

    def _order_status(self, c):
        rows = self._query(
            "SELECT Status FROM Order WHERE QuoteId IN (SELECT Quote__c FROM RLM_RTK_Inspection__c "
            f"WHERE Account__r.Name = '{self._q(c['name'])}') ORDER BY CreatedDate DESC LIMIT 1"
        )
        return rows[0]["Status"] if rows else None

    def _treatment(self, c):
        rows = self._query(
            "SELECT Id, Status, (SELECT Id FROM ServiceAppointments) FROM WorkOrder "
            f"WHERE Account.Name = '{self._q(c['name'])}' AND WorkType.Name = 'Initial Pest Treatment' "
            "ORDER BY CreatedDate DESC LIMIT 1"
        )
        if rows and (rows[0].get("ServiceAppointments") or {}).get("records"):
            return rows[0]
        return None

    def _latest_periods(self, name):
        """Each plan's period in effect today, followed by the changes still to come."""
        today = datetime.date.today().isoformat()
        current, upcoming = {}, []
        for p in self._query(
            "SELECT AssetId, Asset.Product2.Name, StartDate, Quantity, Mrr FROM AssetStatePeriod "
            f"WHERE Asset.Account.Name = '{name}' AND Asset.Product2.StockKeepingUnit LIKE 'RTK-%' "
            "AND Asset.Product2.StockKeepingUnit != 'RTK-INITIAL' ORDER BY StartDate"
        ):
            if p["StartDate"][:10] <= today:
                current[p["AssetId"]] = p
            else:
                upcoming.append(p)
        return list(current.values()) + upcoming

    def _demo_day_work_orders(self, account_name=None):
        day = datetime.date.today() + datetime.timedelta(days=self.options["days_ahead"])
        start, end = (self._utc(day, 0), self._utc(day + datetime.timedelta(days=1), 0))
        where = f" AND Account.Name = '{account_name}'" if account_name else ""
        ids = {
            sa["ParentRecordId"] for sa in self._query(
                "SELECT ParentRecordId FROM ServiceAppointment WHERE ParentRecordType = 'WorkOrder' "
                f"AND SchedStartTime >= {start} AND SchedStartTime < {end}{where}"
            )
        }
        if not ids:
            return []
        return self._query(
            "SELECT Id, WorkOrderNumber, WorkType.Name, RLM_Service_Coverage__c, "
            "(SELECT AppointmentNumber, Status, SchedStartTime FROM ServiceAppointments ORDER BY SchedStartTime) "
            f"FROM WorkOrder WHERE Id IN ({','.join(repr(i) for i in sorted(ids))}) "
            "AND Status NOT IN ('Completed', 'Closed', 'Canceled') ORDER BY WorkOrderNumber"
        )

    # ---------- helpers ----------

    def _apex(self, script, tokens):
        with open(os.path.join(APEX_DIR, script)) as fh:
            apex = "\n".join(line for line in fh.read().splitlines() if not line.lstrip().startswith("//"))
        for key, value in tokens.items():
            apex = apex.replace(f"%%%{key}%%%", _apex_string(value))
        self._run_apex(apex)

    def _run_apex(self, apex):
        result = self.tooling._call_salesforce(
            method="GET", url=f"{self.tooling.base_url}executeAnonymous", params={"anonymousBody": apex}
        ).json()
        if not result.get("compiled"):
            raise CommandException(f"Apex did not compile (line {result.get('line')}): {result.get('compileProblem')}")
        if not result.get("success"):
            raise CommandException(result.get("exceptionMessage") or "Anonymous Apex failed")

    def _wait(self, check, what):
        deadline = time.time() + self.options["timeout"]
        while True:
            value = check()
            if value:
                return value
            if time.time() > deadline:
                raise CommandException(f"Timed out waiting for {what}. Re-run the task to pick up where it stopped.")
            self.logger.info(f"  waiting for {what}...")
            time.sleep(15)

    def _query(self, soql):
        return self.sf.query_all(soql)["records"]

    def _count(self, soql):
        return self.sf.query(soql)["totalSize"]

    @staticmethod
    def _q(value):
        return str(value).replace("\\", "\\\\").replace("'", "\\'")

    @staticmethod
    def _utc(day, hour):
        """SOQL datetime for an hour on the territory's clock."""
        local = datetime.datetime.combine(day, datetime.time(hour), tzinfo=CENTRAL)
        return local.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    @staticmethod
    def _central(utc):
        stamp = datetime.datetime.strptime(utc[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
        return stamp.astimezone(CENTRAL).strftime("%a %b %d %I:%M %p Central")
