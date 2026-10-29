"""
Seed Rentokil pest demo visits: a new prospect's inspection or a Covered re-service.

Runs an Apex script whose ``%%%NAME%%%`` tokens are filled from task options
(``account_name`` fills ``%%%ACCOUNT_NAME%%%``). Values are escaped for Apex
string literals. After the script runs, the task reports the work order and
appointment it booked, plus the guarantee and response milestone for a
re-service, so a bad seed shows up in the task output.

Usage:
    cci task run seed_rtk_prospect_inspection --org dev \
        -o account_name "Nora Castillo" -o street "512 Sycamore Ln" -o hour 15
    cci task run seed_rtk_reservice --org dev \
        -o account_name "Casey Morgan" -o pest Rodents -o hour 8
"""

try:
    from cumulusci.core.exceptions import CommandException, TaskOptionsError
    from cumulusci.tasks.apex.anon import AnonymousApexTask
except ImportError:
    AnonymousApexTask = object
    CommandException = Exception
    TaskOptionsError = Exception


def _apex_string(value):
    return str(value).replace("\\", "\\\\").replace("'", "\\'").replace("\n", " ")


class SeedRtkVisit(AnonymousApexTask):
    """Runs a seeding script with named tokens, then reports what it booked."""

    task_options = {
        **getattr(AnonymousApexTask, "task_options", {}),
        "path": {"description": "Apex script to run.", "required": True},
        "account_name": {"description": "Customer account name.", "required": True},
        "street": {"description": "Street for a new prospect (Bloomingdale, IL 60108).", "required": False},
        "phone": {"description": "Contact phone for a new prospect.", "required": False},
        "pest": {"description": "Reported pest for a re-service, e.g. Ants, Rodents, Termites.", "required": False},
        "subject": {"description": "Work order subject.", "required": False},
        "description": {"description": "Work order description (why the customer called).", "required": False},
        "hour": {"description": "Start hour on the territory's clock, 0-23.", "required": False},
        "days_ahead": {"description": "Days from today. Defaults to 1 (tomorrow).", "required": False},
        "require_coverage": {
            "description": "Re-service only: fail unless a guarantee covers the pest. Defaults to true.",
            "required": False,
        },
    }

    DEFAULTS = {
        "street": "",
        "phone": "",
        "pest": "",
        "subject": "",
        "description": "",
        "hour": "10",
        "days_ahead": "1",
        "require_coverage": "true",
    }

    def _validate_options(self):
        super()._validate_options()
        for name in ("hour", "days_ahead"):
            value = str(self.options.get(name, self.DEFAULTS[name]))
            if not value.isdigit():
                raise TaskOptionsError(f"{name} must be a whole number, got {value!r}")
        if not 0 <= int(self.options.get("hour", self.DEFAULTS["hour"])) <= 23:
            raise TaskOptionsError("hour must be between 0 and 23")

    def _prepare_apex(self, apex):
        apex = super()._prepare_apex(apex)
        for name in ["account_name"] + list(self.DEFAULTS):
            value = self.options.get(name, self.DEFAULTS.get(name, ""))
            apex = apex.replace(f"%%%{name.upper()}%%%", _apex_string(value))
        return apex

    def _run_task(self):
        super()._run_task()
        self._report()

    def _report(self):
        name = _apex_string(self.options["account_name"])
        records = self.sf.query(
            "SELECT Id, WorkOrderNumber, WorkType.Name, Status, Entitlement.Name, MilestoneStatus, "
            "(SELECT AppointmentNumber, Status, SchedStartTime FROM ServiceAppointments ORDER BY CreatedDate) "
            f"FROM WorkOrder WHERE Account.Name = '{name}' ORDER BY LastModifiedDate DESC LIMIT 1"
        )["records"]
        if not records:
            raise CommandException(f"No work order found for {self.options['account_name']} after seeding")
        wo = records[0]
        appointments = (wo.get("ServiceAppointments") or {}).get("records", [])
        self.logger.info(f"{self.options['account_name']}: {wo['WorkType']['Name']}")
        self.logger.info(f"  Work order {wo['WorkOrderNumber']} ({wo['Status']})")
        for sa in appointments:
            self.logger.info(f"  Appointment {sa['AppointmentNumber']} {sa['Status']}")
            self.logger.info(f"  Starts {sa['SchedStartTime']} UTC")
        if wo["WorkType"]["Name"] != "Pest Re-service":
            return
        guarantee = (wo.get("Entitlement") or {}).get("Name")
        milestones = self.sf.query(
            "SELECT MilestoneType.Name, TargetDate FROM EntityMilestone "
            f"WHERE ParentEntityId = '{wo['Id']}' AND IsCompleted = false"
        )["records"]
        self.logger.info(f"  Covered by: {guarantee or 'nothing (Not Covered)'}")
        for m in milestones:
            self.logger.info(f"  {m['MilestoneType']['Name']} due {m['TargetDate']} UTC")
        if guarantee and not milestones:
            self.logger.warning(
                "  Covered, but no open response milestone. Deploy the SLA bundle (deploy_post_pest_sla) "
                "and check the guarantee's entitlement process."
            )
