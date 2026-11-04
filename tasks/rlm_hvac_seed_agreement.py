"""
Seed a Brightline HVAC customer with an active comfort agreement, by running the real sale.

Drives the same Apex the Field Service app calls, one stage per transaction, and picks up
where the customer is: system check booked, systems and findings recorded, quote, proposal
PDF, signature, activated order, Initial Tune-up booked and completed with its checklist and
approved repairs. Completing the tune-up starts agreement billing, the per-system
entitlements and the maintenance plan, which the task waits for and reports.

Re-running for a customer who already has an agreement only reports what they have.

Usage:
    cci task run seed_hvac_agreement_customer --org hvac \
        -o account_name "Dana Whitfield" -o street "77 Brookdale Dr" -o plan Plus -o iaq true
"""

import os
import time

try:
    from cumulusci.core.exceptions import CommandException, TaskOptionsError
    from cumulusci.tasks.salesforce import BaseSalesforceApiTask
except ImportError:
    BaseSalesforceApiTask = object
    CommandException = Exception
    TaskOptionsError = Exception

from tasks.rlm_rtk_seed_visit import _apex_string

PLANS = {"Basic": "HVAC-BASIC", "Plus": "HVAC-PLUS", "Premier": "HVAC-PREMIER"}
SYSTEM_TYPES = ("AcFurnace", "HeatPump")
PROSPECT_SCRIPT = os.path.join("scripts", "apex", "seedHvacProspectCheck.apex")


def _bool(value):
    return str(value).strip().lower() in ("true", "1", "yes")


class SeedHvacAgreementCustomer(BaseSalesforceApiTask):
    """Runs the new-customer sale end to end so the customer has a live comfort agreement."""

    task_options = {
        "account_name": {"description": "Customer account name. Must be new or a prospect without an agreement.", "required": True},
        "street": {"description": "Street for a new customer (Naperville, IL 60540). Each needs its own address.", "required": False},
        "phone": {"description": "Contact phone for a new customer.", "required": False},
        "plan": {"description": "Comfort agreement tier: Basic, Plus or Premier. Defaults to Plus.", "required": False},
        "system_type": {"description": "AcFurnace or HeatPump. Defaults to AcFurnace.", "required": False},
        "systems": {"description": "Number of systems in the home, 1-4. Defaults to 1.", "required": False},
        "install_year": {"description": "Install year of the equipment. Defaults to 2015.", "required": False},
        "iaq": {"description": "Add the Indoor Air Quality add-on. Defaults to false.", "required": False},
        "water_heater": {"description": "Add water heater coverage. Defaults to false.", "required": False},
        "repair": {"description": "Find and fix a weak capacitor on the tune-up. Defaults to true.", "required": False},
        "timeout": {"description": "Seconds to wait for each asynchronous step. Defaults to 300.", "required": False},
    }

    def _init_options(self, kwargs):
        super()._init_options(kwargs)
        o = self.options
        self.plan = (o.get("plan") or "Plus").strip().title()
        self.system_type = (o.get("system_type") or "AcFurnace").strip()
        self.systems = str(o.get("systems") or "1").strip()
        self.install_year = str(o.get("install_year") or "2015").strip()
        self.iaq = _bool(o.get("iaq") or "false")
        self.water_heater = _bool(o.get("water_heater") or "false")
        self.repair = _bool(o.get("repair") or "true")
        self.timeout = int(o.get("timeout") or 300)
        self.name = o["account_name"]

    def _validate_options(self):
        super()._validate_options()
        if self.plan not in PLANS:
            raise TaskOptionsError(f"plan must be Basic, Plus or Premier, got {self.plan!r}")
        if self.system_type not in SYSTEM_TYPES:
            raise TaskOptionsError(f"system_type must be AcFurnace or HeatPump, got {self.system_type!r}")
        if not self.systems.isdigit() or not 1 <= int(self.systems) <= 4:
            raise TaskOptionsError("systems must be 1-4")
        if not self.install_year.isdigit() or len(self.install_year) != 4:
            raise TaskOptionsError("install_year must be a 4-digit year")

    # --- helpers -------------------------------------------------------------------------

    def _apex(self, stage, body):
        self.logger.info(f"{stage}...")
        result = self.tooling._call_salesforce(
            method="GET",
            url=f"{self.tooling.base_url}executeAnonymous",
            params={"anonymousBody": body},
        ).json()
        if not result.get("compiled"):
            raise CommandException(f"{stage}: Apex did not compile: {result.get('compileProblem')}")
        if not result.get("success"):
            raise CommandException(f"{stage} failed: {result.get('exceptionMessage')}")

    def _query(self, soql):
        return self.sf.query(soql)["records"]

    def _wait(self, what, check):
        deadline = time.time() + self.timeout
        while True:
            value = check()
            if value:
                return value
            if time.time() > deadline:
                raise CommandException(f"Timed out after {self.timeout}s waiting for {what}. Re-run the task to continue.")
            self.logger.info(f"  waiting for {what}...")
            time.sleep(10)

    def _q(self):
        return _apex_string(self.name)

    def _account(self):
        rows = self._query(f"SELECT Id FROM Account WHERE Name = '{self._q()}' LIMIT 1")
        return rows[0]["Id"] if rows else None

    def _check_visit(self, account_id):
        rows = self._query(
            "SELECT Id, WorkOrderNumber, Status, RLM_HVAC_Assessment__c, RLM_HVAC_Assessment__r.Quote__c "
            f"FROM WorkOrder WHERE AccountId = '{account_id}' AND WorkType.Name = 'System Check' "
            "ORDER BY CreatedDate DESC LIMIT 1"
        )
        return rows[0] if rows else None

    def _agreements(self, account_id):
        return self._query(
            "SELECT Name, RLM_HVAC_Covered_Systems__c FROM Entitlement "
            f"WHERE AccountId = '{account_id}' AND RLM_HVAC_Covered_Systems__c != null "
            "AND StartDate <= TODAY AND (EndDate = null OR EndDate >= TODAY)"
        )

    # --- stages --------------------------------------------------------------------------

    def _book_check(self):
        with open(PROSPECT_SCRIPT) as f:
            apex = f.read()
        values = {
            "ACCOUNT_NAME": self.name,
            "STREET": self.options.get("street") or "",
            "PHONE": self.options.get("phone") or "",
            "SUBJECT": "",
            "DESCRIPTION": "",
            "HOUR": "8",
            "DAYS_AHEAD": "0",
        }
        for key, value in values.items():
            apex = apex.replace(f"%%%{key}%%%", _apex_string(value))
        self._apex("Booking the system check", apex)

    def _assess(self, wo_id):
        repair = ""
        if self.repair:
            repair = (
                "RLM_HVAC_Assessment.FindingInput f1 = new RLM_HVAC_Assessment.FindingInput();\n"
                "f1.equipment = 'Outdoor Unit'; f1.component = 'Capacitor'; f1.condition = 'Worn'; f1.urgency = 'Repair Soon';\n"
                f"f1.make = 'Carrier'; f1.installYear = {self.install_year}; f1.reading = '32 uF (rated 45 uF)';\n"
                "f1.customerNote = 'The run capacitor is weak, which strains the compressor on hot days.';\n"
                "RLM_HVAC_Assessment.saveFinding(aId, f1);\n"
            )
        self._apex(
            "Recording the systems and findings",
            f"Id aId = RLM_HVAC_FieldVisit.startAssessment('{wo_id}');\n"
            f"RLM_HVAC_Assessment.saveSystems(aId, '{self.system_type}', {self.systems});\n"
            f"{repair}"
            "RLM_HVAC_Assessment.FindingInput f2 = new RLM_HVAC_Assessment.FindingInput();\n"
            "f2.equipment = 'Furnace'; f2.component = 'Filter'; f2.condition = 'Clogged'; f2.urgency = 'Monitor';\n"
            f"f2.make = 'Carrier'; f2.installYear = {self.install_year}; f2.customerNote = 'The filter is overdue for a change.';\n"
            "RLM_HVAC_Assessment.saveFinding(aId, f2);\n",
        )

    def _quote(self, wo_id, assessment_id):
        sku = PLANS[self.plan]
        repairs = "String.join(rec.repairSkus, ',')" if self.repair else "null"
        self._apex(
            f"Creating the {self.plan} quote",
            f"RLM_HVAC_Assessment.Recommendation rec = RLM_HVAC_Assessment.getState('{assessment_id}').recommendation;\n"
            f"String reason = rec.planSku == '{sku}' ? null : 'Customer chose {self.plan}.';\n"
            f"RLM_HVAC_FieldVisit.createQuote('{wo_id}', '{sku}', '{self.system_type}', rec.equipmentAge, {self.systems}, "
            f"{str(self.iaq).lower()}, {str(self.water_heater).lower()}, "
            f"{repairs}, reason);\n",
        )

    def _sign(self, quote_id):
        self._apex("Generating the proposal", f"RLM_HVAC_FieldVisit.startProposal('{quote_id}');")

        def ready():
            rows = self._query(
                "SELECT Id, Status FROM DocumentGenerationProcess "
                f"WHERE ReferenceObject = '{quote_id}' ORDER BY CreatedDate DESC LIMIT 1"
            )
            if rows and rows[0]["Status"] == "Failure":
                raise CommandException("Proposal generation failed. Check the RLM_HVAC_Proposal template is active.")
            return rows[0]["Id"] if rows and rows[0]["Status"] == "Success" else None

        process_id = self._wait("the proposal PDF", ready)
        self._apex(
            "Signing and paying",
            f"RLM_HVAC_FieldVisit.ProposalStatus s = RLM_HVAC_FieldVisit.proposalStatus('{process_id}', '{quote_id}');\n"
            "if (s.status != 'Ready') throw new IllegalArgumentException('Proposal not ready: ' + s.message);\n"
            f"RLM_SignAndPay.AcceptResponse r = RLM_SignAndPay.accept('{quote_id}', s.contentDocumentId, "
            f"'{self._q()}', '4242', 'Visa');\n"
            "if (r.success != true) throw new IllegalArgumentException(r.message);\n",
        )

    def _tune_up(self, quote_id):
        def found():
            rows = self._query(
                "SELECT Id, WorkOrderNumber, Status, "
                "(SELECT Id, Status FROM ServiceAppointments ORDER BY CreatedDate LIMIT 1) "
                f"FROM WorkOrder WHERE RLM_Order__r.QuoteId = '{quote_id}' AND WorkType.Name = 'Initial Tune-up' LIMIT 1"
            )
            if rows and (rows[0].get("ServiceAppointments") or {}).get("records"):
                return rows[0]
            return None

        return self._wait("fulfillment to create the Initial Tune-up", found)

    def _complete_tune_up(self, wo, quote_id):
        sa = wo["ServiceAppointments"]["records"][0]
        if sa["Status"] not in ("Dispatched", "In Progress"):
            self._apex(
                "Booking the Initial Tune-up",
                f"List<RLM_HVAC_FieldVisit.Slot> slots = RLM_HVAC_FieldVisit.tuneUpSlots('{sa['Id']}');\n"
                "if (slots.isEmpty()) throw new IllegalArgumentException('No open tune-up slots this week.');\n"
                f"RLM_HVAC_FieldVisit.bookTuneUp('{sa['Id']}', slots[0].startTime, '{quote_id}');\n",
            )
        self._apex(
            "Running the tune-up checklist",
            f"Id wo = '{wo['Id']}';\n"
            f"RLM_HVAC_FieldVisit.startVisit('{sa['Id']}');\n"
            "Map<String, String> readings = new Map<String, String>{ 'thermostat' => '71', 'capacitor' => '44 uF', "
            "'refrigerant' => '118 psi / 10F', 'co' => '0', 'split' => '19' };\n"
            "Map<String, Object> saved = new Map<String, Object>();\n"
            "for (RLM_HVAC_Assessment.ServiceStep st : RLM_HVAC_Assessment.getWorkOrderFindings(wo).steps) {\n"
            "    saved.put(st.key, new Map<String, Object>{ 'done' => true, 'reading' => readings.get(st.key) });\n"
            "}\n"
            "update new WorkOrder(Id = wo, RLM_HVAC_Service_Steps__c = JSON.serialize(saved));\n",
        )
        self._apex(
            "Fixing the findings",
            f"Id wo = '{wo['Id']}';\n"
            "for (RLM_HVAC_Assessment.FindingView f : RLM_HVAC_Assessment.getWorkOrderFindings(wo).findings) {\n"
            "    if (f.workStatus == 'Done') continue;\n"
            "    Boolean cap = f.component == 'Capacitor';\n"
            "    RLM_HVAC_Assessment.saveWork(wo, f.id, 'Done', cap ? 'Replaced with a 35/5 uF dual run capacitor' "
            ": 'Replaced with a 16x25x1 MERV 11 filter', cap ? '35 uF' : null);\n"
            "}\n",
        )
        self._apex(
            "Completing the tune-up",
            f"RLM_HVAC_FieldVisit.completeVisit('{wo['Id']}');\n"
            # Show the visit when it ran, so it doesn't hold the slot it was booked into.
            f"List<ServiceAppointment> done = [SELECT Id, ActualStartTime, ActualEndTime FROM ServiceAppointment WHERE ParentRecordId = '{wo['Id']}'];\n"
            "for (ServiceAppointment s : done) { s.SchedStartTime = s.ActualStartTime; s.SchedEndTime = s.ActualEndTime; }\n"
            "update done;\n",
        )

    def _close_check(self, wo_id):
        self._apex(
            "Closing the system check",
            f"RLM_HVAC_FieldVisit.completeVisit('{wo_id}');\n"
            f"List<ServiceAppointment> done = [SELECT Id, ActualStartTime, ActualEndTime FROM ServiceAppointment WHERE ParentRecordId = '{wo_id}'];\n"
            "for (ServiceAppointment s : done) { s.SchedStartTime = s.ActualStartTime; s.SchedEndTime = s.ActualEndTime; }\n"
            "update done;\n",
        )

    # --- run -----------------------------------------------------------------------------

    def _run_task(self):
        account_id = self._account()
        if account_id and self._agreements(account_id):
            self.logger.info(f"{self.name} already has an active comfort agreement.")
            self._report(account_id)
            return

        check = self._check_visit(account_id) if account_id else None
        if not check:
            if not self.options.get("street"):
                raise TaskOptionsError("Pass -o street for a new customer; each needs its own address.")
            self._book_check()
            account_id = self._account()
            check = self._check_visit(account_id)

        if not check["RLM_HVAC_Assessment__c"]:
            self._assess(check["Id"])
            check = self._check_visit(account_id)
        elif not self._query(f"SELECT Id FROM RLM_HVAC_Finding__c WHERE Assessment__c = '{check['RLM_HVAC_Assessment__c']}' LIMIT 1"):
            self._assess(check["Id"])

        quote_id = (check.get("RLM_HVAC_Assessment__r") or {}).get("Quote__c")
        if not quote_id:
            self._quote(check["Id"], check["RLM_HVAC_Assessment__c"])
            quote_id = self._check_visit(account_id)["RLM_HVAC_Assessment__r"]["Quote__c"]

        quote = self._query(f"SELECT QuoteNumber, RLM_Demo_Signed_At__c FROM Quote WHERE Id = '{quote_id}'")[0]
        self.logger.info(f"  Quote {quote['QuoteNumber']}")
        if not quote["RLM_Demo_Signed_At__c"]:
            self._sign(quote_id)
        self._apex("Placing and activating the order", f"RLM_HVAC_FieldVisit.placeOrder('{quote_id}');")

        if check["Status"] != "Completed":
            self._close_check(check["Id"])

        tune_up = self._tune_up(quote_id)
        if tune_up["Status"] != "Completed":
            self._complete_tune_up(tune_up, quote_id)

        self._wait("the agreement entitlements", lambda: self._agreements(account_id))
        self._wait(
            "the tune-up invoice",
            lambda: self._query(
                f"SELECT Id FROM Invoice WHERE BillingAccountId = '{account_id}' AND Status = 'Posted' "
                "AND Id IN (SELECT InvoiceId FROM InvoiceLine WHERE Product2.StockKeepingUnit = 'HVAC-TUNEUP')"
            ),
        )
        self._report(account_id)

    def _report(self, account_id):
        self.logger.info(f"{self.name}: comfort agreement customer")
        for e in self._agreements(account_id):
            self.logger.info(f"  Agreement: {e['Name']} covers {e['RLM_HVAC_Covered_Systems__c'].replace(';', ', ')}")
        for p in self._query(
            "SELECT MaintenancePlanNumber, (SELECT WorkOrderNumber, WorkType.Name, SuggestedMaintenanceDate "
            "FROM WorkOrders WHERE Status = 'New' ORDER BY SuggestedMaintenanceDate LIMIT 3) "
            f"FROM MaintenancePlan WHERE AccountId = '{account_id}'"
        ):
            self.logger.info(f"  Maintenance plan {p['MaintenancePlanNumber']}")
            for w in (p.get("WorkOrders") or {}).get("records", []):
                self.logger.info(f"    Upcoming {w['WorkType']['Name']} {w['SuggestedMaintenanceDate']} (work order {w['WorkOrderNumber']})")
        for i in self._query(
            "SELECT DocumentNumber, Status, TotalAmountWithTax FROM Invoice "
            f"WHERE BillingAccountId = '{account_id}' ORDER BY CreatedDate"
        ):
            self.logger.info(f"  Invoice {i['DocumentNumber']} {i['Status']} ${i['TotalAmountWithTax']:.2f}")
        self.logger.info(
            f"Next: cci task run seed_hvac_service_call -o account_name \"{self.name}\" -o issue \"No Cool\" -o hour 8"
        )
